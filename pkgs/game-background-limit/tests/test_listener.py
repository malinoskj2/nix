import importlib.util
import os
from pathlib import Path
import signal
import json
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "limiter", Path(__file__).resolve().parents[1] / "game_background_limit.py"
)
limiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(limiter)


class FocusTests(unittest.TestCase):
    def test_game_exit_status_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            mango = runtime / "mangohud"
            mango.write_text('#!/bin/sh\nexec "$@"\n')
            mango.chmod(0o755)
            environment = dict(os.environ)
            environment.update(
                XDG_RUNTIME_DIR=str(runtime),
                XDG_CACHE_HOME=str(runtime),
                GAME_BACKGROUND_MANGOHUD=str(mango),
                GAME_BACKGROUND_HYPRCTL="/unavailable",
            )
            result = subprocess.run(
                [sys.executable, str(spec.origin), "/bin/sh", "-c", "exit 7"],
                env=environment,
                capture_output=True,
                timeout=3,
            )
            self.assertEqual(result.returncode, 7)
            self.assertFalse(list(runtime.glob("game-background-limit/launch-*")))

    def test_focus_and_multiple_instances(self):
        windows = [{"address": "a", "pid": 1}, {"address": "b", "pid": 2}]

        def owns(window):
            return window["pid"] == 1

        self.assertEqual(limiter.desired_limit(windows, {"address": "a"}, owns), 0)
        self.assertEqual(limiter.desired_limit(windows, {"address": "b"}, owns), 10)
        self.assertEqual(limiter.desired_limit(windows, {}, owns), 10)
        self.assertEqual(limiter.desired_limit([], {}, owns), 0)
        # Another window of the same launch keeps that entire launch uncapped.
        self.assertEqual(limiter.desired_limit(windows, {"address": "b"}, lambda _: True), 0)

    def test_process_marker_avoids_app_id_collisions(self):
        with patch.object(Path, "read_bytes", return_value=b"MANGOHUD_CONFIGFILE=/one\0"):
            self.assertTrue(limiter.owns_window({"pid": 10}, "/one"))
            self.assertFalse(limiter.owns_window({"pid": 10}, "/two"))
        with patch.object(Path, "read_bytes", side_effect=PermissionError):
            self.assertFalse(limiter.owns_window({"pid": 10}, "/one"))

    def test_config_keeps_inode_and_writes_only_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            config = limiter.Config(Path(directory) / "hud.conf")
            before = config.path.stat()
            config.set_limit(0)
            self.assertEqual(before.st_mtime_ns, config.path.stat().st_mtime_ns)
            config.set_limit(10)
            self.assertEqual(before.st_ino, config.path.stat().st_ino)
            self.assertIn("fps_limit=10\n", config.path.read_text())
            config.set_limit(0)
            self.assertIn("fps_limit=00\n", config.path.read_text())
            self.assertIn("no_display\n", config.path.read_text())

    def test_watchdog_uncaps_on_listener_death(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hud.conf"
            listener = os.fork()
            if listener == 0:
                config = limiter.Config(path)
                limiter.watchdog(config)
                config.set_limit(10)
                while True:
                    signal.pause()
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if path.exists() and "fps_limit=10\n" in path.read_text():
                        break
                    time.sleep(0.01)
                self.assertIn("fps_limit=10\n", path.read_text())
                os.kill(listener, signal.SIGKILL)
                os.waitpid(listener, 0)
                listener = None
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if "fps_limit=00\n" in path.read_text():
                        break
                    time.sleep(0.01)
                self.assertIn("fps_limit=00\n", path.read_text())
            finally:
                if listener is not None:
                    os.kill(listener, signal.SIGKILL)
                    os.waitpid(listener, 0)

    def test_event_listener_startup_focus_close_and_disconnect(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            socket_dir = runtime / "hypr" / "test"
            socket_dir.mkdir(parents=True)
            pid_file = runtime / "pid"
            state_file = runtime / "state"
            state_file.write_text(json.dumps({"clients": [], "activewindow": {}}))
            hyprctl = runtime / "hyprctl"
            hyprctl.write_text(
                f"#!{sys.executable}\n"
                "import json, pathlib, sys\n"
                "command = sys.argv[-1]\n"
                "if command == 'instances': print('[{\"instance\":\"test\"}]')\n"
                "elif command == 'monitors': print('[{\"name\":\"DP-1\"}]')\n"
                f"else: print(json.dumps(json.loads(pathlib.Path({str(state_file)!r}).read_text())[command]))\n"
            )
            hyprctl.chmod(0o755)
            mango = runtime / "mangohud"
            mango.write_text('#!/bin/sh\nexec "$@"\n')
            mango.chmod(0o755)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(socket_dir / ".socket2.sock"))
            server.listen()
            server.settimeout(3)
            environment = dict(os.environ)
            environment.update(
                XDG_RUNTIME_DIR=str(runtime),
                XDG_CACHE_HOME=str(runtime),
                GAME_BACKGROUND_HYPRCTL=str(hyprctl),
                GAME_BACKGROUND_MANGOHUD=str(mango),
            )
            game_code = (
                f"import os,pathlib,time;pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()));time.sleep(30)"
            )
            wrapper = subprocess.Popen(
                [sys.executable, str(spec.origin), sys.executable, "-c", game_code],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            connection = None
            try:
                connection, _ = server.accept()
                deadline = time.monotonic() + 3
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                game_pid = int(pid_file.read_text())
                path = next(runtime.glob("game-background-limit/launch-*/MangoHud.conf"))

                def wait_limit(value):
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        if f"fps_limit={value:02d}\n" in path.read_text():
                            return
                        time.sleep(0.01)
                    self.fail(f"did not set FPS limit {value}")

                def event(windows, active, name):
                    state_file.write_text(json.dumps({"clients": windows, "activewindow": active}))
                    connection.sendall(f"{name}>>\n".encode())

                game = {"address": "game", "pid": game_pid}
                wait_limit(0)
                event([game], {}, "openwindow")
                wait_limit(10)
                event([game], {"address": "game"}, "activewindowv2")
                wait_limit(0)
                event([game], {}, "activewindowv2")
                wait_limit(10)
                event([], {}, "closewindow")
                wait_limit(0)
                event([game], {}, "openwindow")
                wait_limit(10)
                connection.close()
                server.close()
                wait_limit(0)
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                (socket_dir / ".socket2.sock").unlink()
                server.bind(str(socket_dir / ".socket2.sock"))
                server.listen()
                server.settimeout(3)
                connection, _ = server.accept()
                wait_limit(10)
                # A malformed response releases the cap and reconnects.
                state_file.write_text(json.dumps({"clients": None, "activewindow": {}}))
                connection.sendall(b"activewindowv2>>\n")
                wait_limit(0)
                connection.close()
                state_file.write_text(json.dumps({"clients": [game], "activewindow": {}}))
                connection, _ = server.accept()
                wait_limit(10)
                # Invalid event bytes cannot terminate the game or leave it capped.
                connection.sendall(b"\xff>>\n")
                wait_limit(0)
                connection.close()
                connection, _ = server.accept()
                wait_limit(10)
                # Kill the actual launcher/listener; the independent watchdog
                # releases its cap while the test game remains alive.
                wrapper.kill()
                wrapper.wait(timeout=3)
                wait_limit(0)
                os.kill(game_pid, 0)
            finally:
                if connection is not None:
                    connection.close()
                server.close()
                if wrapper.poll() is None:
                    wrapper.terminate()
                    wrapper.wait(timeout=3)
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGTERM)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
