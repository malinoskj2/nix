import argparse
import contextlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
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
KILL_GRACE = 5


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
        ], True
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
        ], True
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
    ], False


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


def stop_group(proc):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + KILL_GRACE
        while time.monotonic() < deadline:
            proc.poll()
            try:
                os.killpg(proc.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)


def ask(member, prompt, prompt_path, out_dir, timeout, results):
    answer = out_dir / f"{member}.md"
    log = out_dir / f"{member}.log"
    argv, feeds_stdin = command(member, prompt, prompt_path, answer, timeout)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    start = time.monotonic()
    result = {"member": member, "answer": answer, "log": log}
    with contextlib.ExitStack() as files:
        stdin = files.enter_context(open(prompt_path if feeds_stdin else os.devnull, "rb"))
        log_file = files.enter_context(open(log, "xb"))
        stdout = log_file if member == "codex" else files.enter_context(open(answer, "xb"))
        try:
            proc = subprocess.Popen(
                argv,
                stdin=stdin,
                stdout=stdout,
                stderr=log_file,
                env=env,
                start_new_session=True,
            )
        except FileNotFoundError:
            result["status"] = f"failed: {argv[0]} not found on PATH"
        else:
            try:
                code = proc.wait(timeout=timeout)
                result["status"] = "ok" if code == 0 else f"failed: exit {code}"
            except subprocess.TimeoutExpired:
                result["status"] = f"failed: timed out after {timeout}s"
            finally:
                stop_group(proc)
    if result["status"] == "ok" and (not answer.exists() or not answer.read_text(errors="replace").strip()):
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
        body = r["answer"].read_text(errors="replace") if r["answer"].exists() else ""
        if r["status"] != "ok":
            body = (body + "\n\n" if body.strip() else "") + "Log tail:\n\n" + r.get("log_tail", "(empty)")
        sections.append((member, body.strip()))
        combined.append(f"## {LABELS[member]} ({r['status']})\n\n{body.strip()}")
    council = out_dir / "council.md"
    council.write_text("\n\n".join(combined) + "\n")

    header = "\n".join([f"Council output: {council}", *status])
    heads = [f"\n\n## {LABELS[m]} ({results[m]['status']})\n\n" for m, _ in sections]
    notices = [f"\n[truncated; full text in {results[m]['answer']}]" for m, _ in sections]
    fixed = sum(len(x.encode()) for x in [header, "\n", *heads, *notices])
    budget = max(0, (STDOUT_BUDGET - fixed) // len(sections))
    out = [header]
    for (member, body), head, notice in zip(sections, heads, notices):
        encoded = body.encode()
        if len(encoded) > budget:
            body = clip(encoded, budget) + notice
        out.append(head + body)
    sys.stdout.buffer.write(clip(("".join(out) + "\n").encode(), STDOUT_BUDGET).encode())


def clip(data, limit):
    return data[:limit].decode("utf-8", errors="ignore")


def default_out_dir():
    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        root = os.getcwd()
    parent = Path(root) / ".tmp" / "council"
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=parent))


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
    if args.out_dir:
        out_dir = Path(args.out_dir).resolve()
        try:
            out_dir.mkdir(parents=True)
        except FileExistsError:
            parser.error(f"--out-dir {out_dir} already exists; give a new directory")
    else:
        out_dir = default_out_dir().resolve()
    prompt_path = out_dir / "prompt.md"
    with open(prompt_path, "x", opener=lambda path, flags: os.open(path, flags, 0o600)) as f:
        f.write(prompt)

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
