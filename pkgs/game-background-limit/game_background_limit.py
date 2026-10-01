"""One launch, one config; Hyprland events drive supported MangoHud reloads."""

import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile


CONFIG = """no_display
cpu_stats=0
gpu_stats=0
fps=0
frame_timing=0
fps_limit={limit}
fps_limit_method=late
toggle_hud=
toggle_fps_limit=
toggle_logging=
autostart_log=0
"""
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


class Config:
    def __init__(self, path):
        self.path = Path(path)
        self.limit = None
        self.set_limit(0)

    def set_limit(self, limit):
        if limit != self.limit:
            # Preserve the inode MangoHud watches. Values are the same length,
            # so a single overwrite avoids a truncate/read race on reload.
            data = CONFIG.format(limit=f"{limit:02d}").encode()
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
            try:
                os.pwrite(fd, data, 0)
            finally:
                os.close(fd)
            self.limit = limit


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


def owns_window(window, config_path):
    try:
        environment = Path(f"/proc/{int(window['pid'])}/environ").read_bytes()
        marker = f"MANGOHUD_CONFIGFILE={config_path}".encode()
        return marker in environment.split(b"\0")
    except (KeyError, ValueError, OSError):
        return False


def desired_limit(windows, active, owned):
    game_windows = [window for window in windows if owned(window)]
    if not game_windows:
        return 0
    if any(window["address"] == active.get("address") for window in game_windows):
        return 0
    return 10


def reconcile(signature, config):
    windows = hypr(signature, "clients")
    active = hypr(signature, "activewindow")
    config.set_limit(desired_limit(windows, active, lambda window: owns_window(window, config.path)))


def watchdog(config):
    """Uncap even if the listener is killed without running its finally block."""
    reader, writer = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(writer)
        os.setsid()
        try:
            while os.read(reader, 1):
                pass
            config.limit = None
            config.set_limit(0)
        finally:
            os._exit(0)
    os.close(reader)
    return pid, writer


def monitor(child, config, runtime):
    child_fd = os.pidfd_open(child.pid)
    try:
        while child.poll() is None:
            config.set_limit(0)
            try:
                signature = physical_signature()
                path = runtime / "hypr" / signature / ".socket2.sock"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as events:
                    events.settimeout(2)
                    events.connect(str(path))
                    events.setblocking(False)
                    reconcile(signature, config)
                    buffered = b""
                    while child.poll() is None:
                        ready, _, _ = select.select([events, child_fd], [], [])
                        if child_fd in ready:
                            return
                        data = events.recv(65536)
                        if not data:
                            raise OSError("Hyprland event socket disconnected")
                        buffered += data
                        if len(buffered) > 1024 * 1024:
                            raise ValueError("oversized Hyprland event")
                        lines = buffered.split(b"\n")
                        buffered = lines.pop()
                        if any(line.partition(b">>")[0].decode() in EVENTS for line in lines):
                            reconcile(signature, config)
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
                config.set_limit(0)
                print(f"game-background-limit: uncapped: {error}", file=sys.stderr)
                select.select([child_fd], [], [], 1)
    finally:
        config.set_limit(0)
        os.close(child_fd)


def main():
    if len(sys.argv) == 1 or sys.argv[1] in ("--help", "-h"):
        print(
            "Usage: game-background-limit COMMAND [ARGS...]\n"
            "Steam launch options: game-background-limit %command%\n"
            "Hidden MangoHud; 10 FPS unfocused, no MangoHud cap focused."
        )
        return 0
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    # Pressure-vessel creates a private /run/user. Home/cache remains shared,
    # so both the outer listener and inner rendering process see the same file.
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "game-background-limit"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="launch-", dir=cache))
    config = Config(directory / "MangoHud.conf")
    guard_pid, guard_fd = watchdog(config)
    child = None

    def terminate(signum, _frame):
        config.set_limit(0)
        if child is not None and child.poll() is None:
            child.send_signal(signum)
        raise InterruptedError

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        environment = os.environ.copy()
        environment.pop("MANGOHUD_CONFIG", None)
        environment["MANGOHUD_CONFIGFILE"] = str(config.path)
        child = subprocess.Popen([os.environ["GAME_BACKGROUND_MANGOHUD"], *sys.argv[1:]], env=environment)
        try:
            monitor(child, config, runtime)
        except InterruptedError:
            pass
        result = child.wait()
        return result if result >= 0 else 128 - result
    finally:
        config.set_limit(0)
        os.close(guard_fd)
        os.waitpid(guard_pid, 0)
        config.path.unlink(missing_ok=True)
        directory.rmdir()


if __name__ == "__main__":
    sys.exit(main())
