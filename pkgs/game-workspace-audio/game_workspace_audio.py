"""Mute Steam playback while workspace 5 is hidden, preserving user mute states."""

import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def command(name, *args):
    return subprocess.run(
        [os.environ.get("GAME_AUDIO_" + name.upper().replace("-", "_"), name), *map(str, args)],
        capture_output=True,
        check=True,
        timeout=2,
    ).stdout


def hypr(signature, query):
    value = json.loads(command("hyprctl", *(["-i", signature] if signature else []), "-j", query))
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise ValueError("unexpected Hyprland response")
    return value


def physical_session():
    # User services also see nested agent compositors; never use their workspaces.
    sessions = []
    for instance in hypr(None, "instances"):
        signature = instance["instance"]
        if any(
            not monitor.get("disabled", False)
            and re.fullmatch(r"(?:DP|HDMI-A|eDP|DVI-[DI]|VGA|LVDS)-\d+", monitor["name"])
            for monitor in hypr(signature, "monitors")
        ):
            sessions.append(signature)
    if len(sessions) != 1:
        raise OSError("expected one physical Hyprland session")
    return sessions[0]


def process_game(pid):
    try:
        process = Path(f"/proc/{int(pid)}")
        name = process.joinpath("comm").read_text().strip()
        if name.startswith(("steam", "srt-")):
            return None
        environment = dict(
            entry.split(b"=", 1) for entry in process.joinpath("environ").read_bytes().split(b"\0") if b"=" in entry
        )
        app = environment.get(b"SteamAppId", b"").decode("ascii")
        if re.fullmatch(r"[1-9][0-9]*", app):
            return app
    except (OSError, ValueError, TypeError, UnicodeError):
        pass
    return None


def hidden_games(windows, monitors, game_for_pid=process_game):
    visible = {
        monitor.get("activeWorkspace", {}).get("id") for monitor in monitors if not monitor.get("disabled", False)
    }
    visible.update(monitor.get("specialWorkspace", {}).get("id") for monitor in monitors)
    games = {}
    for window in windows:
        # Steam's own UI is never a game, even if it has inherited environment.
        if window.get("class", "").lower() in ("steam", "steamwebhelper"):
            continue
        app = game_for_pid(window.get("pid"))
        if not app:
            match = re.fullmatch(r"steam_app_([1-9][0-9]*)", window.get("class", ""))
            app = match[1] if match else None
        if app:
            workspace = window.get("workspace", {}).get("id")
            games.setdefault(app, []).append(workspace == 5 and workspace not in visible)
    # Keep a game audible if another one of its windows is outside workspace 5.
    return {app for app, states in games.items() if states and all(states)}


def streams(snapshot, game_for_pid=process_game):
    core = next((item["info"]["cookie"] for item in snapshot if item.get("type") == "PipeWire:Interface:Core"), None)
    if core is None:
        raise ValueError("PipeWire core unavailable")
    result = {}
    for item in snapshot:
        info = item.get("info") or {}
        props = info.get("props", {})
        if item.get("type") != "PipeWire:Interface:Node" or props.get("media.class") != "Stream/Output/Audio":
            continue
        app = game_for_pid(props.get("application.process.id"))
        mute = next((param["mute"] for param in info.get("params", {}).get("Props", []) if "mute" in param), None)
        if not app or not isinstance(mute, bool) or "object.serial" not in props:
            continue
        # Match WirePlumber's stream-properties key so recreated streams inherit
        # the original mute, including a game restarted after exiting while hidden.
        key = next(
            (
                [name, props[name]]
                for name in ("media.role", "application.id", "application.name", "media.name", "node.name")
                if props.get(name)
            ),
            None,
        )
        if key is None:
            continue
        identity = json.dumps([core, props["object.serial"]])
        result[identity] = {"id": item["id"], "app": app, "key": json.dumps([app, *key]), "mute": mute}
    return result


class Controller:
    def __init__(self, path, set_mute=None):
        self.path = path
        self.set_mute = set_mute
        try:
            self.saved = json.loads(path.read_text())
            if not isinstance(self.saved, dict) or any(
                not isinstance(value, dict) or not value or any(not isinstance(mute, bool) for mute in value.values())
                for value in self.saved.values()
            ):
                raise ValueError("invalid audio restoration journal")
        except FileNotFoundError:
            self.saved = {}

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.saved))
        temporary.chmod(0o600)
        temporary.replace(self.path)

    def reconcile(self, current, hidden):
        by_key = {}
        for identity, stream in current.items():
            by_key.setdefault(stream["key"], []).append((identity, stream))
        for key, members in by_key.items():
            background = members[0][1]["app"] in hidden
            if background and key not in self.saved:
                # A manual mute is already sufficient; never claim ownership.
                if all(stream["mute"] for _, stream in members):
                    continue
                self.saved[key] = {identity: stream["mute"] for identity, stream in members}
                self.save()  # Journal before changing anything, for crash recovery.
            if key not in self.saved:
                continue
            originals = self.saved[key]
            for identity, stream in members:
                if identity not in originals:
                    # A recreated stream can inherit the automated mute from
                    # WirePlumber. Inherit the prior application's original state.
                    originals[identity] = all(originals.values()) if stream["mute"] else False
                    self.save()
                target = True if background else originals[identity]
                if stream["mute"] != target:
                    if self.set_mute:
                        self.set_mute(stream["id"], target)
                    else:
                        # IDs are recycled; revalidate serial/core and game
                        # immediately before addressing the node through wpctl.
                        latest = streams(json.loads(command("pw-dump"))).get(identity)
                        if not latest or latest["id"] != stream["id"] or latest["key"] != key:
                            raise OSError("audio stream changed before mute update")
                        command("wpctl", "set-mute", stream["id"], int(target))
            if not background:
                del self.saved[key]
                self.save()
        # Keep absent streams in the journal: WirePlumber can remember our mute
        # across a stream/game restart. Only a verified Steam game with the same
        # application and restore key can consume that restoration record.


def main():
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "game-workspace-audio"
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
    with state.joinpath("lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        controller = Controller(state / "mute.json")
        signature = None

        def stop(_signum, _frame):
            raise InterruptedError

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            while True:
                current = streams(json.loads(command("pw-dump")))
                try:
                    signature = signature or physical_session()
                    hidden = hidden_games(hypr(signature, "clients"), hypr(signature, "monitors"))
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    signature = None
                    hidden = set()  # Loss of compositor IPC restores audible state.
                controller.reconcile(current, hidden)
                # Polling also covers new/recreated streams and changes in a
                # game's process tree without maintaining multiple IPC readers.
                time.sleep(0.5)
        except InterruptedError:
            pass
        finally:
            controller.reconcile(streams(json.loads(command("pw-dump"))), set())
    return 0


if __name__ == "__main__":
    sys.exit(main())
