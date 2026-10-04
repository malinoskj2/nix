#!/usr/bin/env python3
"""Sync Orca's managed hooks into a sandbox without replacing other agent state."""

import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib


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
            replacement = f"trusted_hash = {json.dumps(hashes[current_key])}\n"
            if line != replacement:
                lines[index] = replacement
    # An existing managed section without a hash is malformed; do not append a
    # duplicate table and make the entire Codex config unreadable.
    missing = hashes.keys() - found
    if missing:
        raise ValueError(f"managed Codex trust entries missing trusted_hash: {sorted(missing)}")
    return "".join(lines)


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
    changed_hashes = {}
    for key, value in source_state.items():
        if not key.startswith(source_prefix):
            continue
        target_key = target_prefix + key[len(source_prefix) :]
        trusted_hash = value.get("trusted_hash")
        if not isinstance(trusted_hash, str):
            continue
        if target_key in target_state:
            if target_state[target_key].get("trusted_hash") != trusted_hash:
                changed_hashes[target_key] = trusted_hash
            continue
        additions.append(f"[hooks.state.{json.dumps(target_key)}]\n")
        additions.append(f"trusted_hash = {json.dumps(trusted_hash)}\n")
        if "enabled" in value:
            additions.append(f"enabled = {'true' if value['enabled'] else 'false'}\n")
        additions.append("\n")
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
        sync_managed_file(
            host_hooks / "claude-settings.json", sandbox_hooks / "claude-settings.json", 0o600
        )
        sync_managed_file(
            host_home / ".config/orca/codex-runtime-home/home/hooks.json",
            sandbox_home / ".codex/hooks.json",
            0o600,
        )
        add_codex_trust(host_home, sandbox_home)


if __name__ == "__main__":
    main()
