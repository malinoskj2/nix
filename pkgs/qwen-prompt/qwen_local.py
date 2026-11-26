"""Model table, readiness, OpenCode configuration and llama.cpp handling shared by the Qwen launchers."""

import ctypes
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

MODELS = {
    "regular": ("qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf"),
    "uncensored": ("qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf"),
}

# --moe (llama.cpp) and --strata serve Qwen3.6-35B-A3B; Strata only runs mixture-of-experts files.
MOE_MODELS = {
    "regular": ("qwen3.6-35b-a3b", "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"),
    "uncensored": ("qwen3.6-35b-a3b-uncensored", "Huihui-Qwen3.6-35B-A3B-abliterated-Q4_K.gguf"),
}
# Strata sizes its buffers and expert cache to whatever VRAM is free (29.3-30.3 GiB
# measured at every context, --expert-vram included), above the 28.5 GiB the
# scheduler grants a shared request, so it books the whole GPU.
STRATA_BOOKING = ("--exclusive",)

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


def mode_of(args):
    """dense (the default), moe or strata, from a launcher's --moe and --strata flags."""
    return "strata" if args.strata else "moe" if args.moe else "dense"


def model_alias(name, mode="dense"):
    return (MODELS if mode == "dense" else MOE_MODELS)[name][0]


def server_binary(mode):
    return "strata-server" if mode == "strata" else "llama-server"


def resolve_model(name, mode="dense"):
    """Return the pinned GGUF for a model name, refusing anything not fully ready."""
    root = Path(os.environ.get("MODEL_ROOT", str(Path.home() / ".local/share/models")))
    alias, filename = (MODELS if mode == "dense" else MOE_MODELS)[name]
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


# What strata_tokenizer.py always writes into <out>/tokenizer; chat_template.jinja only exists when the GGUF has one.
TOKENIZER_FILES = ("vocab.json", "merges.txt", "tokenizer.json", "token_type.json")


def tokenizer_complete(tokenizer):
    try:
        for name in TOKENIZER_FILES:
            if (tokenizer / name).stat().st_size == 0:
                return False
        for name in TOKENIZER_FILES:
            if name.endswith(".json"):
                json.loads((tokenizer / name).read_text())
    except (OSError, ValueError):
        return False
    return True


def strata_tokenizer(model):
    """Strata's server reads the vocabulary from a directory it derives from the GGUF; build it once per model file.

    Extraction runs in a private directory that is renamed into place only once
    complete, so an interrupted or concurrent run never leaves a cache that
    looks finished. An incomplete cache is rebuilt.
    """
    root = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "qwen-prompt" / "strata"
    final = root / model.name
    tokenizer = final / "tokenizer"
    if tokenizer_complete(tokenizer):
        return tokenizer
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{model.name}.", dir=root))
    try:
        subprocess.run(["strata-tokenizer", "--gguf", str(model), "--out", str(staging)], check=True, stdout=sys.stderr)
        if not tokenizer_complete(staging / "tokenizer"):
            raise RuntimeError(f"Strata's tokenizer extraction for {model.name} left an incomplete tokenizer")
        for _ in range(3):
            if tokenizer_complete(tokenizer):
                return tokenizer
            if final.exists():
                stale = Path(tempfile.mkdtemp(prefix=f".{model.name}.stale.", dir=root))
                try:
                    os.rename(final, stale / "old")
                except FileNotFoundError:
                    pass
                shutil.rmtree(stale, ignore_errors=True)
            try:
                os.rename(staging, final)
                staging = None
                return tokenizer
            except OSError:
                continue
        raise RuntimeError(f"Cannot publish Strata's tokenizer cache at {final}")
    finally:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)


def strata_command(model, port, key, context, directory):
    """Strata's server with one slot, its MTP drafts and an f16 KV cache.

    At 256k the routed experts that don't fit beside the cache stay in pinned
    system RAM (all 18.75 GiB are pinned once any are offloaded).
    """
    config = Path(directory) / "strata.json"
    config.write_text(
        json.dumps(
            {
                "arch": "qwen35moe",
                "exe": shutil.which("strata") or "strata",
                "model_name": "qwen",
                "tokenizer": str(strata_tokenizer(model)),
                "log": str(Path(directory) / "strata-engine.log"),
                "args": [
                    "--native",
                    str(model),
                    "--max-context",
                    str(context),
                    "--prefill",
                    "auto",
                    "--mtp",
                    "2",
                    "--kv",
                    "fp16",
                ],
            }
        )
    )
    return [
        "strata-server",
        "--engine",
        "strata",
        "--config",
        str(config),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--api-key",
        key,
        "--offline",
    ]


def server_command(model, port, key, context, mode, directory):
    if mode == "strata":
        return strata_command(model, port, key, context, directory)
    return llama_command(model, port, key, context)


def healthy(port, key):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/health", headers={"Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            if response.status != 200:
                return False
            # Strata answers while its engine is still loading and says so.
            body = response.read()
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return False
    try:
        return json.loads(body or b"{}").get("loaded") is not False
    except (ValueError, AttributeError):
        return True


def wait_healthy(server, port, key, timeout):
    deadline = time.monotonic() + timeout
    while not healthy(port, key):
        if server.poll() is not None:
            raise RuntimeError(f"the Qwen server exited with code {server.returncode}")
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
    if argv[0] in ("llama-server", "strata-server") and not os.environ.get("GPU_LEASE_ID"):
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
