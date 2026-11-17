"""One scheduled, foreground OpenCode task with a private llama.cpp server."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


MODELS = {
    "regular": ("qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf"),
    "uncensored": ("qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf"),
}


def opencode_major(version):
    match = re.match(r"(?:opencode\s+)?v?(\d+)\.", version.strip())
    if match is None:
        raise RuntimeError(f"Unrecognized OpenCode version: {version!r}")
    return int(match.group(1))


def stop(process):
    if process is None:
        return
    # Kill the whole private group, including any remaining tool descendants.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def configuration(port, major):
    model = {"name": "Local Qwen", "limit": {"context": 16384, "output": 4096}}
    if major == 2:
        return {
            "$schema": "https://opencode.ai/config.json",
            "model": "local-qwen/qwen",
            "small_model": "local-qwen/qwen",
            "enabled_providers": ["local-qwen"],
            "update": "disable",
            "share": "disabled",
            "warming": False,
            "providers": {
                "local-qwen": {
                    "package": "@opencode/ai/providers/openai-compatible",
                    "name": "Local Qwen",
                    "env": ["QWEN_LOCAL_API_KEY"],
                    "settings": {"baseURL": f"http://127.0.0.1:{port}/v1"},
                    "models": {"qwen": model},
                }
            },
        }
    raise RuntimeError(f"OpenCode major version {major} has not been validated by this runner")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=MODELS, required=True)
    parser.add_argument("--prompt-file", type=Path, required=True)
    parser.add_argument("--project", required=True, help="Stable scheduler project key")
    parser.add_argument("--timeout", type=int, default=1800, help="Execution limit in seconds")
    parser.add_argument("--allocated", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    prompt = args.prompt_file.read_bytes().decode("utf-8")
    if not prompt.strip() or "\0" in prompt:
        parser.error("prompt must be nonempty UTF-8 and contain no NUL")
    for command in ("opencode", "llama-server", "resource-run"):
        if not shutil.which(command):
            raise RuntimeError(f"Missing {command}; deploy the qwen-prompt Nix package first")
    root = Path(os.environ.get("MODEL_ROOT", str(Path.home() / ".local/share/models")))
    alias, filename = MODELS[args.model]
    catalog = json.loads((root / "catalog.json").read_text())
    readiness = json.loads((root / "readiness.json").read_text())
    model = root / "by-name" / alias / filename
    if alias not in catalog["entries"] or readiness["entries"][alias]["status"] != "ready":
        raise RuntimeError(f"Local model {alias} is not ready; no download or fallback attempted")
    expected = next(f["size"] for f in catalog["entries"][alias]["files"] if f["target"] == filename)
    if not model.is_file() or model.stat().st_size != expected:
        raise RuntimeError(f"Missing or incomplete model: {model}")
    if not args.allocated:
        if os.environ.get("RESOURCE_JOB_ID") or os.environ.get("GPU_LEASE_ID"):
            raise RuntimeError("Already inside a reservation; invoke from outside it to avoid exceeding its budgets")
        if Path("/etc/resource-scheduler/mode").read_text().strip() != "slurm":
            raise RuntimeError("This runner requires the deployed Slurm resource scheduler")
        # Fixed 16k context, one slot, full GPU offload. Budgets include weights,
        # KV cache and workspace margin; they are declarations, not measurements.
        command = [
            "resource-run",
            "--cpu",
            "4",
            "--ram",
            "24GiB",
            "--vram",
            "26GiB",
            "--project",
            args.project,
            "--profile",
            "qwen-prompt",
            "--variant",
            f"{alias}-q5-16k-v1",
            "--category",
            "inference",
            "--name",
            f"Qwen prompt ({args.model})",
            "--",
            sys.executable,
            str(Path(__file__).resolve()),
            "--model",
            args.model,
            "--prompt-file",
            str(args.prompt_file.resolve()),
            "--project",
            args.project,
            "--timeout",
            str(args.timeout),
            "--allocated",
        ]
        os.execvp(command[0], command)
    if not os.environ.get("RESOURCE_JOB_ID"):
        raise RuntimeError("--allocated requires a scheduler allocation")
    version = subprocess.check_output(["opencode", "--version"], text=True).strip()
    major = opencode_major(version)
    # Validate the harness before starting the GPU process.
    configuration(1, major)
    server = harness = None

    def interrupted(signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        with tempfile.TemporaryDirectory(prefix="qwen-prompt-") as directory:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            key = secrets.token_hex(24)
            config = Path(directory) / "opencode.json"
            config.write_text(json.dumps(configuration(port, major)))
            env = os.environ.copy()
            env["OPENCODE_CONFIG_CONTENT"] = config.read_text()
            env["OPENCODE_CONFIG"] = str(config)
            env["QWEN_LOCAL_API_KEY"] = key
            env["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
            # --auto makes the requested task unattended; OpenCode still honors
            # explicit deny rules from the project and managed configuration.
            server = subprocess.Popen(
                [
                    "llama-server",
                    "--model",
                    str(model),
                    "--alias",
                    "qwen",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--api-key",
                    key,
                    "--ctx-size",
                    "16384",
                    "--parallel",
                    "1",
                    "--threads",
                    "4",
                    "--n-gpu-layers",
                    "99",
                    "--jinja",
                ],
                stdout=sys.stderr,
                stderr=sys.stderr,
                start_new_session=True,
            )
            deadline = time.monotonic() + min(args.timeout, 300)
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/health", headers={"Authorization": f"Bearer {key}"}
            )
            while True:
                if server.poll() is not None:
                    raise RuntimeError(f"llama-server exited with code {server.returncode}")
                try:
                    with urllib.request.urlopen(request, timeout=2) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError):
                    pass
                if time.monotonic() >= deadline:
                    raise RuntimeError("Timed out loading Qwen")
                time.sleep(0.5)
            harness = subprocess.Popen(
                [
                    "opencode",
                    "run",
                    "--standalone",
                    "--auto",
                    "--model",
                    "local-qwen/qwen",
                    "--format",
                    "json",
                ],
                env=env,
                stdin=subprocess.PIPE,
                start_new_session=True,
            )
            harness.communicate(input=prompt.encode("utf-8"), timeout=args.timeout)
            return harness.returncode
    finally:
        stop(harness)
        stop(server)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"qwen-prompt: {error}", file=sys.stderr)
        sys.exit(1)
