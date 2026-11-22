"""Reconcile Nix-owned Orca installs and initial repository bases through the native CLI."""

import json
import os
from pathlib import Path
import subprocess
import sys


class OrcaError(Exception):
    def __init__(self, response):
        self.response = response
        super().__init__(json.dumps(response))


def call(cli, *args):
    process = subprocess.run([cli, *args, "--json"], capture_output=True, text=True, timeout=120)
    try:
        response = json.loads(process.stdout)
    except ValueError as error:
        raise RuntimeError(process.stderr or process.stdout) from error
    if process.returncode or not response.get("ok"):
        raise OrcaError(response.get("error", response))
    return response["result"]


def reconcile_plugins(cli, desired):
    installed = {p["pluginKey"]: p for p in call(cli, "plugin", "list")["plugins"]}
    for key, folder in desired.items():
        previous = installed.get(key, {})
        # Native install grants consent and enables. Respect a deliberate disable or dev override;
        # migrate those bytes only after the user re-enables/removes their development folder.
        if previous.get("status") == "disabled" or previous.get("isDev"):
            continue
        source = previous.get("source", {})
        if source.get("kind") == "local-path" and source.get("reference") == folder:
            continue
        try:
            call(cli, "plugin", "install", folder)
        except OrcaError as error:
            request = error.response
            data = request.get("data", {})
            # Only approve the exact declaratively pinned package, with the fingerprint Orca
            # returned. Never execute the suggested shell command or approve arbitrary plugins.
            if (
                request.get("code") != "approval_required"
                or data.get("pluginKey") != key
                or not isinstance(data.get("approvalFingerprint"), str)
            ):
                raise
            call(
                cli,
                "plugin",
                "install",
                folder,
                "--approve",
                data["approvalFingerprint"],
            )


def reconcile_bases(cli, desired, initialized):
    for repo in call(cli, "repo", "list")["repos"]:
        path = repo["path"]
        if (
            path not in desired
            or repo["id"] in initialized
            or repo.get("connectionId")
            or repo.get("executionHostId") not in (None, "local")
            or repo.get("kind") == "folder"
        ):
            continue
        # Existing persisted choices (including origin/main) are authoritative.
        if not repo.get("worktreeBaseRef"):
            ref = desired[path]
            if subprocess.run(
                ["git", "-C", path, "show-ref", "--verify", "--quiet", f"refs/heads/{ref}"],
                check=False,
            ).returncode:
                continue
            # Re-read immediately before seeding to preserve a newly selected custom base.
            current = call(cli, "repo", "show", "--repo", f"id:{repo['id']}")["repo"]
            if not current.get("worktreeBaseRef"):
                call(cli, "repo", "set-base-ref", "--repo", f"id:{repo['id']}", "--ref", ref)
        initialized.add(repo["id"])


def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    state = Path(sys.argv[2])
    initialized = set(json.loads(state.read_text())) if state.exists() else set()
    # No startup, UI launch or host discovery: a stopped runtime simply retries on the next timer.
    reconcile_plugins(config["cli"], config["plugins"])
    reconcile_bases(config["cli"], config["baseRefs"], initialized)
    state.parent.mkdir(parents=True, exist_ok=True)
    temporary = state.with_suffix(".new")
    temporary.write_text(json.dumps(sorted(initialized)) + "\n")
    os.replace(temporary, state)


if __name__ == "__main__":
    try:
        main()
    except (OrcaError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Orca declarative setup deferred: {error}", file=sys.stderr)
        sys.exit(1)
