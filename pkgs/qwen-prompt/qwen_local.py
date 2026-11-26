"""Model table, readiness, OpenCode configuration and llama.cpp and Strata handling shared by the Qwen launchers."""

import ctypes
import fcntl
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

# --moe serves Qwen3.8-Flash-Next through Strata. Its 512-expert layers only fit
# in Strata's low-RAM resident mode: the GPU's expert cache is fixed at load, and
# system RAM holds only the experts it doesn't (about 22-24 GiB of the 42.9 GB at
# 64k-256k). Strata fits its buffers and cache to the whole free card (29.3-30.3
# GiB measured), above the 28.5 GiB the scheduler grants a shared request.
MOE_MODELS = {
    "regular": ("qwen3.8-flash-next", "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf"),
    "uncensored": (
        "qwen3.8-flash-next-uncensored",
        "Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_XXS-00001-of-00002.gguf",
    ),
}
MOE_BOOKING = ("--exclusive",)

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
    """dense (the default) or moe, from a launcher's --moe flag."""
    return "moe" if args.moe else "dense"


def model_alias(name, mode="dense"):
    return (MODELS if mode == "dense" else MOE_MODELS)[name][0]


def server_binary(mode):
    return "strata-server" if mode == "moe" else "llama-server"


def resolve_model(name, mode="dense"):
    """Return the pinned GGUF for a model name, refusing anything not fully ready."""
    root = Path(os.environ.get("MODEL_ROOT", str(Path.home() / ".local/share/models")))
    alias, filename = (MODELS if mode == "dense" else MOE_MODELS)[name]
    catalog = json.loads((root / "catalog.json").read_text())
    readiness = json.loads((root / "readiness.json").read_text())
    model = root / "by-name" / alias / filename
    if alias not in catalog["entries"] or readiness["entries"][alias]["status"] != "ready":
        raise RuntimeError(f"Local model {alias} is not ready; no download or fallback attempted")
    for file in catalog["entries"][alias]["files"]:
        path = model.parent / file["target"]
        if not path.is_file() or path.stat().st_size != file["size"]:
            raise RuntimeError(f"Missing or incomplete model: {path}")
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


def pack_complete(pack):
    """iq_pack.py writes native_experts.txt last; the resident mode also reads experts.bin."""
    try:
        if (pack / "native_experts.txt").stat().st_size == 0 or (pack / "experts.bin").stat().st_size == 0:
            return False
        for name in ("vocab.json", "tokenizer.json"):
            json.loads((pack / "tokenizer" / name).read_text())
    except (OSError, ValueError):
        return False
    return True


def strata_pack(model):
    """Strata's pack for a Flash-Next GGUF: its tensor index, tokenizer and experts.bin, built once per model file.

    One build runs at a time per model, under a lock, in a private directory
    that is renamed into place only once complete, so an interrupted run never
    leaves a pack that looks finished. A build killed outright leaves its
    staging directory behind; the next build removes it.
    """
    root = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "qwen-prompt" / "strata"
    final = root / model.name
    if pack_complete(final):
        return final
    root.mkdir(parents=True, exist_ok=True)
    with open(root / f"{model.name}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if pack_complete(final):
            return final
        for leftover in root.glob(f".{model.name}.*"):
            shutil.rmtree(leftover, ignore_errors=True)
        staging = Path(tempfile.mkdtemp(prefix=f".{model.name}.", dir=root))
        try:
            print(f"Preparing Strata's pack for {model.name} (once, about 43 GB) ...", file=sys.stderr, flush=True)
            built = staging / "pack"
            subprocess.run(
                ["strata-pack", "--gguf", str(model), "--out", str(built), "--experts-bin"],
                check=True,
                stdout=sys.stderr,
            )
            if not pack_complete(built):
                raise RuntimeError(f"Strata's pack for {model.name} is incomplete")
            if final.exists():
                os.rename(final, staging / "old")
            os.rename(built, final)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    return final


def strata_share():
    return Path(shutil.which("strata") or "strata").resolve().parent.parent / "share" / "strata" / "terminal"


def strata_command(model, port, key, context, directory):
    """Strata's server for Flash-Next: one slot, MTP drafts, an int8 KV cache in VRAM and the resident low-RAM mode.

    The n-gram table (shard 2) stays on disk and is read a few rows per token.
    """
    pack = strata_pack(model)
    share = strata_share()
    config = Path(directory) / "strata.json"
    config.write_text(
        json.dumps(
            {
                "arch": "qwen4exp",
                "exe": shutil.which("strata") or "strata",
                "cwd": str(share),
                "model_name": "qwen",
                "tokenizer": str(pack / "tokenizer"),
                "log": str(Path(directory) / "strata-engine.log"),
                "args": [
                    "--pack",
                    str(pack),
                    "--native",
                    str(model),
                    "--ple-gguf",
                    str(model.with_name(model.name.replace("-00001-of-", "-00002-of-"))),
                    "--expert-profile",
                    str(share / "data" / "expert-profile.bin"),
                    "--expert-cache",
                    "auto",
                    "--prefill",
                    "auto",
                    "--spec",
                    "4",
                    "--spec-min-p",
                    "0.5",
                    "--mtp",
                    str(model.parent / "mtp" / "rt"),
                    "--max-context",
                    str(context),
                    "--kv",
                    "int8",
                    "--resident-experts",
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
    if mode == "moe":
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
