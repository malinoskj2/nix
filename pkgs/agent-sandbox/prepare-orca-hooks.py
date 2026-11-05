#!/usr/bin/env python3

import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib

CODEX_RUNTIME_HOME = Path(".config/orca/codex-runtime-home/home")


def atomic_write(destination: Path, content: bytes, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
        temp.write(content)
        temp_path = Path(temp.name)
    try:
        temp_path.chmod(mode)
        os.replace(temp_path, destination)
    finally:
        temp_path.unlink(missing_ok=True)


def sync_managed_file(source: Path, destination: Path, mode: int) -> None:
    if not source.is_file():
        return
    content = source.read_bytes()
    if destination.is_file() and destination.read_bytes() == content:
        return
    atomic_write(destination, content, mode)


def update_trust_hashes(config: str, hashes: dict[str, str]) -> str:
    """Replace only managed trusted_hash values; retain per-hook enabled choices."""
    lines = config.splitlines(keepends=True)
    current_key = None
    found = set()
    for index, line in enumerate(lines):
        if line.startswith("["):
            current_key = None
            match = re.fullmatch(r"\[hooks\.state\.(.+)\]\s*", line)
            if match:
                try:
                    current_key = tomllib.loads(f"key = {match[1]}")["key"]
                except tomllib.TOMLDecodeError:
                    pass
        elif current_key in hashes and re.match(r"\s*trusted_hash\s*=", line):
            found.add(current_key)
            lines[index] = f"trusted_hash = {json.dumps(hashes[current_key])}\n"
    # An existing managed section without a hash is malformed; do not append a
    # duplicate table and make the entire Codex config unreadable.
    missing = hashes.keys() - found
    if missing:
        raise ValueError(f"managed Codex trust entries missing trusted_hash: {sorted(missing)}")
    return "".join(lines)


def hook_state(config: dict) -> dict:
    return config.get("hooks", {}).get("state", {})


def trusted_hooks(state: dict, prefix: str) -> dict[str, dict]:
    return {
        key.removeprefix(prefix): value
        for key, value in state.items()
        if key.startswith(prefix) and isinstance(value.get("trusted_hash"), str)
    }


def trust_table(key: str, value: dict) -> str:
    table = f"[hooks.state.{json.dumps(key)}]\ntrusted_hash = {json.dumps(value['trusted_hash'])}\n"
    if "enabled" in value:
        table += f"enabled = {json.dumps(bool(value['enabled']))}\n"
    return table + "\n"


def add_codex_trust(host_home: Path, sandbox_home: Path) -> None:
    source_config = host_home / CODEX_RUNTIME_HOME / "config.toml"
    target_config = sandbox_home / ".codex/config.toml"
    if not source_config.is_file() or not target_config.is_file():
        return
    source_state = hook_state(tomllib.loads(source_config.read_text()))
    target_text = target_config.read_text()
    target_state = hook_state(tomllib.loads(target_text))
    source_prefix = f"{host_home / CODEX_RUNTIME_HOME / 'hooks.json'}:"
    target_prefix = f"{host_home / '.codex/hooks.json'}:"
    additions = []
    changed_hashes = {}
    for suffix, value in trusted_hooks(source_state, source_prefix).items():
        target_key = target_prefix + suffix
        if target_key not in target_state:
            additions.append(trust_table(target_key, value))
        elif target_state[target_key].get("trusted_hash") != value["trusted_hash"]:
            changed_hashes[target_key] = value["trusted_hash"]
    if not additions and not changed_hashes:
        return
    updated = update_trust_hashes(target_text, changed_hashes)
    if additions:
        updated = updated.rstrip() + "\n\n" + "".join(additions)
    atomic_write(target_config, updated.encode(), 0o600)


def main() -> None:
    host_home, sandbox_home = map(Path, sys.argv[1:])
    host_hooks = host_home / ".orca/agent-hooks"
    sandbox_hooks = sandbox_home / ".orca/agent-hooks"
    sandbox_hooks.mkdir(parents=True, exist_ok=True)
    with (sandbox_hooks / ".prepare.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for name in ("claude-hook.sh", "codex-hook.sh", "claude-statusline.sh"):
            sync_managed_file(host_hooks / name, sandbox_hooks / name, 0o700)
        sync_managed_file(host_hooks / "claude-settings.json", sandbox_hooks / "claude-settings.json", 0o600)
        sync_managed_file(
            host_home / CODEX_RUNTIME_HOME / "hooks.json",
            sandbox_home / ".codex/hooks.json",
            0o600,
        )
        add_codex_trust(host_home, sandbox_home)


if __name__ == "__main__":
    main()
