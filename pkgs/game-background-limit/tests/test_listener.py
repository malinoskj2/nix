import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

import automatic


class ControllerTests(unittest.TestCase):
    def test_native_owner_start_time_and_inherited_token(self):
        first, second = socket.socketpair()
        try:
            client = automatic.Client(first)
            second.sendall(b"v1 " + b"a" * 32 + b"\n")
            self.assertTrue(client.read())
            self.assertEqual(second.recv(1), b"F")
            self.assertTrue(client.owns({"pid": os.getpid()}))
            with patch.object(automatic, "start_time", return_value=client.start_time + 1):
                self.assertFalse(client.owns({"pid": os.getpid()}))
            with patch.object(automatic, "environment_token", return_value="a" * 32):
                self.assertTrue(client.owns({"pid": -1}))
            client.set_background(True)
            self.assertEqual(second.recv(1), b"B")
            client.set_background(False)
            self.assertEqual(second.recv(1), b"F")
        finally:
            first.close()
            second.close()

    def test_independent_launches_and_grouped_windows(self):
        class Fake:
            def __init__(self, token, pids):
                self.token, self.pids, self.background = token, pids, None

            def owns(self, window):
                return window["pid"] in self.pids

            def set_background(self, background):
                self.background = background

        one, helper, two = Fake("one", [1]), Fake("one", [2]), Fake("two", [3])
        windows = [{"pid": 1, "address": "a"}, {"pid": 2, "address": "b"}, {"pid": 3, "address": "c"}]
        with patch.object(automatic, "hypr", side_effect=[windows, {"address": "b"}]):
            automatic.reconcile("session", {1: one, 2: helper, 3: two})
        self.assertFalse(one.background)
        self.assertFalse(helper.background)
        self.assertTrue(two.background)
        with patch.object(automatic, "hypr", side_effect=[[], {}]):
            automatic.reconcile("session", {1: one, 2: two})
        self.assertFalse(one.background)
        self.assertFalse(two.background)

    def test_daemon_focus_disconnect_and_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            state = base / "state"
            state.write_text(json.dumps({"clients": [], "activewindow": {}}))
            helper = base / "hyprctl"
            helper.write_text(
                textwrap.dedent(f"""\
                    #!{sys.executable}
                    import json, pathlib, sys
                    command = sys.argv[-1]
                    if command == "instances":
                        print('[{{"instance": "test"}}]')
                    elif command == "monitors":
                        print('[{{"name": "DP-1"}}]')
                    else:
                        print(json.dumps(json.loads(pathlib.Path({str(state)!r}).read_text())[command]))
                """)
            )
            helper.chmod(0o755)
            event_path = base / "hypr/test/.socket2.sock"
            event_path.parent.mkdir(parents=True)
            events = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            events.bind(str(event_path))
            events.listen()
            events.settimeout(3)
            control_path = base / "control.sock"
            window = {"pid": os.getpid(), "address": "game"}
            environment = dict(
                os.environ,
                XDG_RUNTIME_DIR=str(base),
                XDG_CACHE_HOME=str(base),
                GAME_BACKGROUND_LIMIT_SOCKET=str(control_path),
                GAME_BACKGROUND_HYPRCTL=str(helper),
            )
            daemon = subprocess.Popen(
                [sys.executable, str(Path(automatic.__file__).with_name("game_background_limit.py")), "--daemon"],
                env=environment,
                stderr=subprocess.DEVNULL,
            )
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(3)
            connection = None

            def update(active, event, expected):
                state.write_text(json.dumps({"clients": [window], "activewindow": active}))
                connection.sendall(event)
                self.assertEqual(client.recv(1), expected)

            try:
                deadline = time.monotonic() + 3
                while not control_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                client.connect(str(control_path))
                client.sendall(b"v1 " + b"b" * 32 + b"\n")
                self.assertEqual(client.recv(1), b"F")
                connection, _ = events.accept()
                update({}, b"openwindow>>\n", b"B")
                update({"address": "game"}, b"activewindowv2>>\n", b"F")
                update({}, b"activewindowv2>>\n", b"B")
                connection.close()
                events.close()
                self.assertEqual(client.recv(1), b"F")
                daemon.terminate()
                self.assertEqual(daemon.wait(timeout=3), 0)
                self.assertEqual(client.recv(1), b"")
            finally:
                if connection is not None:
                    connection.close()
                client.close()
                events.close()
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
