"""Launch a manually selected game, or run the automatic Steam controller."""

import json
import os
import re
import subprocess
import sys

EVENTS = {
    "activewindowv2",
    "openwindow",
    "closewindow",
    "movewindow",
    "movewindowv2",
    "workspace",
    "workspacev2",
    "focusedmon",
}


def hypr(signature, command):
    args = [os.environ["GAME_BACKGROUND_HYPRCTL"]]
    if signature:
        args += ["-i", signature]
    result = subprocess.run([*args, "-j", command], capture_output=True, timeout=2, check=True)
    value = json.loads(result.stdout)
    expected = dict if command == "activewindow" else list
    if not isinstance(value, expected) or (expected is list and not all(isinstance(item, dict) for item in value)):
        raise ValueError(f"unexpected Hyprland {command} response")
    return value


def physical_signature():
    candidates = []
    for instance in hypr(None, "instances"):
        signature = instance["instance"]
        if any(
            not monitor.get("disabled", False) and re.match(r"^(DP|HDMI-A|eDP|DVI-[DI]|VGA|LVDS)-\d+$", monitor["name"])
            for monitor in hypr(signature, "monitors")
        ):
            candidates.append(signature)
    if len(candidates) != 1:
        raise OSError(f"expected one physical Hyprland session, found {len(candidates)}")
    return candidates[0]


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--daemon":
        from automatic import main as daemon

        return daemon()
    if len(sys.argv) == 1 or sys.argv[1] in ("--help", "-h"):
        print(
            "Usage: game-background-limit COMMAND [ARGS...]\nSteam games are enabled automatically. This wrapper enables other games."
        )
        return 0
    environment = dict(os.environ)
    environment["GAME_BACKGROUND_FORCE"] = "1"
    environment["GAME_BACKGROUND_LIMIT_AUTO"] = "0"
    environment["GAME_BACKGROUND_VULKAN"] = "1"
    environment["LD_PRELOAD"] = os.environ["GAME_BACKGROUND_LIB"] + (
        ":" + environment["LD_PRELOAD"] if environment.get("LD_PRELOAD") else ""
    )
    environment["XDG_DATA_DIRS"] = os.environ["GAME_BACKGROUND_DATA"] + (
        ":" + environment["XDG_DATA_DIRS"] if environment.get("XDG_DATA_DIRS") else ""
    )
    # The system service supplies the controller. The manual wrapper can be used
    # on other desktops; without that controller it simply remains uncapped.
    os.execvpe(sys.argv[1], sys.argv[1:], environment)


if __name__ == "__main__":
    sys.exit(main())
