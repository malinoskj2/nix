import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

PREAMBLE = """You are one member of a review council. Two other models answer the same request independently, and the caller weighs all three.
Work read-only: never edit, create or delete files, commit, push or change any state. Reading files and running read-only commands is fine.
Answer the request below. For a review, list each finding with its location, what is wrong, a concrete failure scenario and your confidence. Say plainly when you find nothing.
"""

MEMBERS = ("codex", "claude", "gemini")
INLINE_LIMIT = 100_000
CONTEXT_LIMIT = 400_000
STDOUT_BUDGET = 9_000


def build_prompt(prompt_file, context_files):
    parts = [PREAMBLE, "## Request\n\n" + Path(prompt_file).read_text()]
    for path in context_files:
        parts.append(f"## Context: {Path(path).resolve()}\n\n" + Path(path).read_text())
    return "\n\n".join(parts)


def command(member, prompt, prompt_path, last_message, timeout):
    if member == "codex":
        return [
            "codex",
            "exec",
            "--model",
            "gpt-6.2-sol",
            "-c",
            'model_reasoning_effort="medium"',
            "--sandbox",
            "read-only",
            "--ephemeral",
            "--skip-git-repo-check",
            "--color",
            "never",
            "-o",
            str(last_message),
            "-",
        ], prompt
    if member == "claude":
        return [
            "claude",
            "-p",
            "--model",
            "claude-opus-5-5",
            "--effort",
            "medium",
            "--permission-mode",
            "plan",
            "--tools",
            "Read,Grep,Glob",
            "--no-session-persistence",
            "--output-format",
            "text",
        ], prompt
    if len(prompt.encode()) > INLINE_LIMIT:
        text = f"Read the file {prompt_path} and follow the instructions in it exactly."
    else:
        text = prompt
    return [
        "agy",
        "--model",
        "gemini-4-neon-high",
        "--mode",
        "plan",
        "--output-format",
        "text",
        "--print-timeout",
        f"{timeout}s",
        f"-p={text}",
    ], None


def run_member(member, prompt, prompt_path, out_dir, timeout, results):
    try:
        ask(member, prompt, prompt_path, out_dir, timeout, results)
    except Exception as error:
        results[member] = {
            "member": member,
            "answer": out_dir / f"{member}.md",
            "log": out_dir / f"{member}.log",
            "status": f"failed: {type(error).__name__}: {error}",
            "seconds": 0,
        }


def ask(member, prompt, prompt_path, out_dir, timeout, results):
    answer = out_dir / f"{member}.md"
    log = out_dir / f"{member}.log"
    argv, stdin = command(member, prompt, prompt_path, answer, timeout)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    start = time.monotonic()
    result = {"member": member, "answer": answer, "log": log}
    try:
        with open(log, "wb") as log_file:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE if member != "codex" else log_file,
                stderr=log_file,
                env=env,
                start_new_session=True,
            )
            reader = None
            captured = []
            if member != "codex":
                reader = threading.Thread(target=lambda: captured.append(proc.stdout.read()))
                reader.start()
            if stdin is not None:
                try:
                    proc.stdin.write(stdin.encode())
                    proc.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                code = proc.wait(timeout=timeout)
                result["status"] = "ok" if code == 0 else f"failed: exit {code}"
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                result["status"] = f"failed: timed out after {timeout}s"
            if reader is not None:
                reader.join(timeout=10)
                answer.write_bytes(captured[0] if captured else b"")
    except FileNotFoundError:
        result["status"] = f"failed: {argv[0]} not found on PATH"
    if result["status"] == "ok" and (not answer.exists() or not answer.read_text().strip()):
        result["status"] = "failed: empty answer"
    if result["status"] != "ok" and log.exists():
        tail = log.read_bytes()[-600:].decode(errors="replace").strip()
        if tail:
            result["log_tail"] = tail
    result["seconds"] = round(time.monotonic() - start)
    results[member] = result


LABELS = {
    "codex": "Codex gpt-6.2-sol (medium)",
    "claude": "Claude Opus 5.5 (medium)",
    "gemini": "Gemini 4 Neon (high)",
}


def report(results, members, out_dir):
    combined = [f"# Council: {out_dir}\n"]
    status = []
    for member in members:
        r = results[member]
        status.append(f"- {LABELS[member]}: {r['status']} in {r['seconds']}s, answer {r['answer']}, log {r['log']}")
    combined.append("\n".join(status))
    sections = []
    for member in members:
        r = results[member]
        body = r["answer"].read_text() if r["answer"].exists() else ""
        if r["status"] != "ok":
            body = (body + "\n\n" if body.strip() else "") + "Log tail:\n\n" + r.get("log_tail", "(empty)")
        sections.append((member, body.strip()))
        combined.append(f"## {LABELS[member]} ({r['status']})\n\n{body.strip()}")
    council = out_dir / "council.md"
    council.write_text("\n\n".join(combined) + "\n")

    lines = [f"Council output: {council}", *status]
    budget = max(500, (STDOUT_BUDGET - sum(len(s) for s in lines)) // len(members))
    for member, body in sections:
        if len(body) > budget:
            body = body[:budget] + f"\n[truncated; full text in {results[member]['answer']}]"
        lines.append(f"\n## {LABELS[member]} ({results[member]['status']})\n\n{body}")
    print("\n".join(lines))


def default_out_dir():
    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        root = os.getcwd()
    return Path(root) / ".tmp" / "council" / time.strftime("%Y%m%d-%H%M%S")


def main():
    parser = argparse.ArgumentParser(description="Ask Codex, Claude and Gemini the same question in parallel.")
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--context-file", action="append", default=[])
    parser.add_argument("--out-dir")
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--members", default=",".join(MEMBERS))
    args = parser.parse_args()

    members = [m.strip() for m in args.members.split(",") if m.strip()]
    unknown = [m for m in members if m not in MEMBERS]
    if unknown or not members:
        parser.error(f"members must be drawn from {', '.join(MEMBERS)}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    size = sum(Path(p).stat().st_size for p in [args.prompt_file, *args.context_file])
    if size > CONTEXT_LIMIT:
        parser.error(f"prompt and context total {size} bytes, over {CONTEXT_LIMIT}; pass less context")

    prompt = build_prompt(args.prompt_file, args.context_file)
    out_dir = (Path(args.out_dir) if args.out_dir else default_out_dir()).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = out_dir / "prompt.md"
    prompt_path.touch(mode=0o600)
    prompt_path.write_text(prompt)

    results = {}
    threads = [
        threading.Thread(target=run_member, args=(m, prompt, prompt_path, out_dir, args.timeout, results))
        for m in members
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    report(results, members, out_dir)
    failed = sum(results[m]["status"] != "ok" for m in members)
    sys.exit(0 if failed == 0 else 4 if failed == len(members) else 3)


if __name__ == "__main__":
    main()
