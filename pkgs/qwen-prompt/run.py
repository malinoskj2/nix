"""One scheduled, foreground OpenCode task with a private llama.cpp or Strata server."""

import argparse
import os
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

from qwen_local import (
    MODELS,
    MOE_BOOKING,
    checked_opencode_major,
    configuration,
    mode_of,
    opencode_environment,
    refuse_nesting,
    require,
    resolve_model,
    server_binary,
    server_command,
    stop,
    strata_pack,
    wait_healthy,
)

CONTEXT = 16384


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=MODELS, required=True)
    parser.add_argument("--prompt-file", type=Path, required=True)
    parser.add_argument("--project", default=None, help="Ignored legacy option")
    parser.add_argument("--timeout", type=int, default=1800, help="Execution limit in seconds")
    parser.add_argument(
        "--moe",
        action="store_true",
        help="Run Qwen3.8-Flash-Next through Strata instead of the dense 27B; books the whole GPU",
    )
    parser.add_argument("--allocated", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    prompt = args.prompt_file.read_bytes().decode("utf-8")
    if not prompt.strip() or "\0" in prompt:
        parser.error("prompt must be nonempty UTF-8 and contain no NUL")
    mode = mode_of(args)
    require("opencode", server_binary(mode), "gpu-run")
    model = resolve_model(args.model, mode)
    if not args.allocated:
        refuse_nesting()
        if mode == "moe":
            strata_pack(model)
        # Fixed 16k context, one slot. 26 GiB covers the dense 27B's full GPU
        # offload: weights, KV cache and workspace margin.
        command = [
            "gpu-run",
            *(MOE_BOOKING if mode == "moe" else ("--vram", "26GiB")),
            "--name",
            f"Qwen prompt ({args.model}{'' if mode == 'dense' else ', ' + mode})",
            "--",
            sys.executable,
            str(Path(__file__).resolve()),
            "--model",
            args.model,
            "--prompt-file",
            str(args.prompt_file.resolve()),
            "--timeout",
            str(args.timeout),
            *([] if mode == "dense" else [f"--{mode}"]),
            "--allocated",
        ]
        os.execvp(command[0], command)
    if not os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("--allocated requires a GPU reservation")
    # Validate the harness before starting the GPU process.
    major = checked_opencode_major()
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
            env = opencode_environment(configuration(port, major), key, directory)
            # --auto makes the requested task unattended; OpenCode still honors
            # explicit deny rules from the project and managed configuration.
            server = subprocess.Popen(
                server_command(model, port, key, CONTEXT, mode, directory),
                stdout=sys.stderr,
                stderr=sys.stderr,
                start_new_session=True,
            )
            wait_healthy(server, port, key, min(args.timeout, 300))
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
