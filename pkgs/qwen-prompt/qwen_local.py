"""Model table, readiness, OpenCode configuration and llama.cpp handling shared by the Qwen launchers."""

import ctypes
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

MODELS = {
    "regular": ("qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf"),
    "uncensored": ("qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf"),
}

PR_SET_PDEATHSIG = 1


def opencode_major(version):
    match = re.match(r"(?:opencode\s+)?v?(\d+)\.", version.strip())
    if match is None:
        raise RuntimeError(f"Unrecognized OpenCode version: {version!r}")
    return int(match.group(1))


def checked_opencode_major():
    major = opencode_major(subprocess.check_output(["opencode", "--version"], text=True))
    configuration(1, major)
    return major


def require(*commands):
    for command in commands:
        if not shutil.which(command):
            raise RuntimeError(f"Missing {command}; deploy the qwen-prompt Nix package first")


def resolve_model(name):
    """Return the pinned GGUF for a model name, refusing anything not fully ready."""
    root = Path(os.environ.get("MODEL_ROOT", str(Path.home() / ".local/share/models")))
    alias, filename = MODELS[name]
    catalog = json.loads((root / "catalog.json").read_text())
    readiness = json.loads((root / "readiness.json").read_text())
    model = root / "by-name" / alias / filename
    if alias not in catalog["entries"] or readiness["entries"][alias]["status"] != "ready":
        raise RuntimeError(f"Local model {alias} is not ready; no download or fallback attempted")
    expected = next(f["size"] for f in catalog["entries"][alias]["files"] if f["target"] == filename)
    if not model.is_file() or model.stat().st_size != expected:
        raise RuntimeError(f"Missing or incomplete model: {model}")
    return model


def refuse_nesting():
    if os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("Already inside a GPU reservation; invoke from outside it to avoid exceeding its budget")


def stop(process, grace=10):
    if process is None:
        return
    # Kill the whole private group, including any remaining tool descendants.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def configuration(port, major, context=16384):
    model = {"name": "Local Qwen", "limit": {"context": context, "output": 4096}}
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


def opencode_environment(config, key, directory):
    path = Path(directory) / "opencode.json"
    path.write_text(json.dumps(config))
    env = os.environ.copy()
    env["OPENCODE_CONFIG_CONTENT"] = path.read_text()
    env["OPENCODE_CONFIG"] = str(path)
    env["QWEN_LOCAL_API_KEY"] = key
    env["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
    return env


def llama_command(model, port, key, context=16384):
    """One slot with full GPU offload; callers' VRAM budgets assume exactly these settings."""
    return [
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
        str(context),
        "--parallel",
        "1",
        "--threads",
        "4",
        "--n-gpu-layers",
        "99",
        "--jinja",
    ]


def healthy(port, key):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/health", headers={"Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status == 200
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return False


def wait_healthy(server, port, key, timeout):
    deadline = time.monotonic() + timeout
    while not healthy(port, key):
        if server.poll() is not None:
            raise RuntimeError(f"llama-server exited with code {server.returncode}")
        if time.monotonic() >= deadline:
            raise RuntimeError("Timed out loading Qwen")
        time.sleep(0.5)


def die_with_parent():
    """Ask the kernel to SIGTERM this process when the thread that forked it exits."""
    parent = os.getppid()
    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot set the parent-death signal")
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGTERM)


def guard(argv):
    """Exec argv so that it receives SIGTERM when this process's parent exits.

    A program can ask for this itself after exec, unlike from a preexec hook in a
    threaded parent. llama-server additionally must run inside a reservation.
    """
    if argv[0] == "llama-server" and not os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("The Qwen server requires a GPU reservation")
    die_with_parent()
    os.execvp(argv[0], argv)


def guarded(*argv):
    return [sys.executable, str(Path(__file__).resolve()), *argv]


if __name__ == "__main__":
    try:
        guard(sys.argv[1:])
    except (RuntimeError, OSError) as error:
        print(f"qwen-guard: {error}", file=sys.stderr)
        sys.exit(1)
