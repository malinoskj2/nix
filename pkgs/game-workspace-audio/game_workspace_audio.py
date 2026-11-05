from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

GAME_WORKSPACE = 5
COMMAND_OVERRIDES = {
    "hyprctl": "GAME_AUDIO_HYPRCTL",
    "pw-dump": "GAME_AUDIO_PW_DUMP",
    "wpctl": "GAME_AUDIO_WPCTL",
}


def command(name, *args):
    return subprocess.run(
        [os.environ.get(COMMAND_OVERRIDES[name], name), *map(str, args)],
        capture_output=True,
        check=True,
        timeout=2,
    ).stdout


def hypr(signature, query):
    instance = ["-i", signature] if signature else []
    value = json.loads(command("hyprctl", *instance, "-j", query))
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
            games.setdefault(app, []).append(workspace == GAME_WORKSPACE and workspace not in visible)
    # Keep a game audible if another one of its windows is outside the game workspace.
    return {app for app, states in games.items() if states and all(states)}


@dataclass
class Stream:
    node_id: int
    app: str
    restore_key: str
    muted: bool


@dataclass
class RestorationRecord:
    originals: dict[str, bool]

    @classmethod
    def capture(cls, members):
        # A manual mute is already sufficient; never claim ownership.
        if all(stream.muted for _, stream in members):
            return None
        return cls({identity: stream.muted for identity, stream in members})

    def remember(self, identity, stream):
        if identity in self.originals:
            return False
        # WirePlumber can carry our mute into a recreated stream. Inherit the
        # application's original state unless the new stream is already audible.
        self.originals[identity] = stream.muted and all(self.originals.values())
        return True

    def target(self, identity, background):
        return background or self.originals[identity]


def node_mute(info):
    return next((param["mute"] for param in info.get("params", {}).get("Props", []) if "mute" in param), None)


def restore_key(app, props):
    # Match WirePlumber's stream-properties key so recreated streams inherit
    # the original mute, including a game restarted after exiting while hidden.
    for name in ("media.role", "application.id", "application.name", "media.name", "node.name"):
        if props.get(name):
            return json.dumps([app, name, props[name]])
    return None


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
        mute = node_mute(info)
        if not app or not isinstance(mute, bool) or "object.serial" not in props:
            continue
        key = restore_key(app, props)
        if key is None:
            continue
        identity = json.dumps([core, props["object.serial"]])
        result[identity] = Stream(item["id"], app, key, mute)
    return result


def current_streams():
    return streams(json.loads(command("pw-dump")))


def valid_journal(saved):
    return isinstance(saved, dict) and all(
        isinstance(originals, dict) and originals and all(isinstance(mute, bool) for mute in originals.values())
        for originals in saved.values()
    )


class RestorationJournal:
    def __init__(self, path):
        self.path = path
        try:
            saved = json.loads(path.read_text())
            if not valid_journal(saved):
                raise ValueError("invalid audio restoration journal")
        except FileNotFoundError:
            saved = {}
        self.records = {key: RestorationRecord(originals) for key, originals in saved.items()}

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        saved = {key: record.originals for key, record in self.records.items()}
        temporary.write_text(json.dumps(saved))
        temporary.chmod(0o600)
        temporary.replace(self.path)

    def claim(self, key, record):
        self.records[key] = record
        # Journal before changing anything, for crash recovery.
        self.save()

    def release(self, key):
        del self.records[key]
        self.save()


def set_stream_mute(identity, stream, target):
    # IDs are recycled; revalidate serial/core and game immediately before
    # addressing the node through wpctl.
    latest = current_streams().get(identity)
    if not latest or latest.node_id != stream.node_id or latest.restore_key != stream.restore_key:
        raise OSError("audio stream changed before mute update")
    command("wpctl", "set-mute", stream.node_id, int(target))


class Controller:
    def __init__(self, path, set_mute=set_stream_mute):
        self.journal = RestorationJournal(path)
        self.set_mute = set_mute

    def reconcile(self, current, hidden):
        # Keep absent streams in the journal: WirePlumber can remember our mute
        # across a stream/game restart. Only a verified Steam game with the same
        # application and restore key can consume that restoration record.
        by_key = {}
        for identity, stream in current.items():
            by_key.setdefault(stream.restore_key, []).append((identity, stream))

        for key, members in by_key.items():
            background = members[0][1].app in hidden
            record = self.journal.records.get(key)
            if record is None and background:
                record = RestorationRecord.capture(members)
                if record is not None:
                    self.journal.claim(key, record)
            if record is None:
                continue

            for identity, stream in members:
                if record.remember(identity, stream):
                    self.journal.save()
                target = record.target(identity, background)
                if stream.muted != target:
                    self.set_mute(identity, stream, target)

            if not background:
                self.journal.release(key)


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
                current = current_streams()
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
            controller.reconcile(current_streams(), set())
    return 0


if __name__ == "__main__":
    sys.exit(main())
