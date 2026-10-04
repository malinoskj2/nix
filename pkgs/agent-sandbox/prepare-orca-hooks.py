#!/usr/bin/env python3
"""Seed Orca's managed hooks into a sandbox without replacing SSH state."""

import json
import fcntl
import os
from pathlib import Path
import sys
import tempfile
import tomllib


def write_if_missing(source: Path, destination: Path, mode: int) -> None:
    if not source.is_file() or destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
        temp.write(source.read_bytes())
        temp_path = Path(temp.name)
    try:
        temp_path.chmod(mode)
        os.replace(temp_path, destination)
    finally:
        temp_path.unlink(missing_ok=True)


def add_codex_trust(host_home: Path, sandbox_home: Path) -> None:
    managed_home = host_home / ".config/orca/codex-runtime-home/home"
    sandbox_codex = sandbox_home / ".codex"
    source_config = managed_home / "config.toml"
    target_config = sandbox_codex / "config.toml"
    if not source_config.is_file() or not target_config.is_file():
        return
    source = tomllib.loads(source_config.read_text())
    target_text = target_config.read_text()
    target = tomllib.loads(target_text)
    source_state = source.get("hooks", {}).get("state", {})
    target_state = target.get("hooks", {}).get("state", {})
    source_prefix = str(host_home / ".config/orca/codex-runtime-home/home/hooks.json") + ":"
    target_prefix = str(host_home / ".codex/hooks.json") + ":"
    additions = []
    for key, value in source_state.items():
        if not key.startswith(source_prefix):
            continue
        target_key = target_prefix + key[len(source_prefix) :]
        if target_key in target_state:
            continue
        trusted_hash = value.get("trusted_hash")
        if not isinstance(trusted_hash, str):
            continue
        additions.append(f"[hooks.state.{json.dumps(target_key)}]\n")
        additions.append(f"trusted_hash = {json.dumps(trusted_hash)}\n")
        if "enabled" in value:
            additions.append(f"enabled = {'true' if value['enabled'] else 'false'}\n")
        additions.append("\n")
    if not additions:
        return
    with tempfile.NamedTemporaryFile(dir=target_config.parent, delete=False) as temp:
        temp.write((target_text.rstrip() + "\n\n" + "".join(additions)).encode())
        temp_path = Path(temp.name)
    try:
        temp_path.chmod(0o600)
        os.replace(temp_path, target_config)
    finally:
        temp_path.unlink(missing_ok=True)


def main() -> None:
    host_home, sandbox_home = map(Path, sys.argv[1:])
    host_hooks = host_home / ".orca/agent-hooks"
    sandbox_hooks = sandbox_home / ".orca/agent-hooks"
    sandbox_hooks.mkdir(parents=True, exist_ok=True)
    with (sandbox_hooks / ".prepare.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in ("claude-hook.sh", "codex-hook.sh", "claude-statusline.sh"):
            write_if_missing(host_hooks / name, sandbox_hooks / name, 0o700)
        write_if_missing(
            host_hooks / "claude-settings.json", sandbox_hooks / "claude-settings.json", 0o600
        )
        write_if_missing(
            host_home / ".config/orca/codex-runtime-home/home/hooks.json",
            sandbox_home / ".codex/hooks.json",
            0o600,
        )
        add_codex_trust(host_home, sandbox_home)


if __name__ == "__main__":
    main()
