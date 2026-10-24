#!/usr/bin/env python3
"""Start the sandbox's Steam client, offline whenever a saved login allows it.

Offline, the sandbox client never signs in to Steam's servers, so a game it launches doesn't take
the account's single game session from the human playing on the host.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

import vdf

LOGIN_USERS = Path.home() / ".local/share/Steam/config/loginusers.vdf"


def log(message: str) -> None:
    print(f"sandbox-steam: {message}", file=sys.stderr)


def remembered_users(data: dict) -> list[dict]:
    return [user for user in data.get("users", {}).values() if user.get("RememberPassword") == "1"]


def set_offline(offline: bool) -> bool:
    """Record the mode Steam starts in and return whether it will start offline."""
    try:
        data = vdf.loads(LOGIN_USERS.read_text())
    except FileNotFoundError:
        return False
    users = remembered_users(data)
    if not users:
        return False

    value = "1" if offline else "0"
    for user in users:
        user["WantsOfflineMode"] = value
        user["SkipOfflineModeWarning"] = value
    with tempfile.NamedTemporaryFile("w", dir=LOGIN_USERS.parent, delete=False) as temp:
        temp.write(vdf.dumps(data, pretty=True))
    os.replace(temp.name, LOGIN_USERS)
    return offline


def steam_running() -> bool:
    return subprocess.run(["pgrep", "-x", "steam"], stdout=subprocess.DEVNULL).returncode == 0


def main() -> None:
    args = sys.argv[1:]
    online = args[:1] == ["--online"]
    if online:
        args = args[1:]

    # A running client keeps its mode and rewrites the file when it exits.
    if steam_running():
        log("Steam is already running and keeps its mode; quit it with `steam -shutdown` to change it")
    elif set_offline(not online):
        log("starting Steam offline")
    elif online:
        log("starting Steam online; a game launched now ends one the human is playing on the host")
    else:
        url = os.environ.get("AGENT_SANDBOX_VNC_URL", "the sandbox VNC")
        log(
            f"no saved Steam login, so Steam starts online; ask the human to sign in at {url} with "
            "Remember me checked, then restart it with `steam -shutdown` and sandbox-steam to go offline"
        )

    os.execvpe(
        "nix",
        ["nix", "run", "--impure", "nixpkgs#steam", "--", *args],
        {**os.environ, "NIXPKGS_ALLOW_UNFREE": "1"},
    )


if __name__ == "__main__":
    main()
