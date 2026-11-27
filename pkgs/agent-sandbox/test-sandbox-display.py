import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

SCRIPT = Path(__file__).with_name("sandbox-display.sh")

# Compositor stand-ins: each sway serves its IPC socket and runs what `swaymsg exec` sends it as
# its own child, as sway does, so the nested Hyprland inherits nested sway's descriptors.
SWAY = """
import os, socket, subprocess, sys
runtime = os.environ["XDG_RUNTIME_DIR"]
path = os.environ["SWAYSOCK"] if "--config" in sys.argv else os.path.join(runtime, "wayland-1")
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen()
while True:
    connection, _ = server.accept()
    request = connection.recv(4096).decode()
    if request.startswith("exec "):
        subprocess.Popen(request[5:].split(), stdin=subprocess.DEVNULL, close_fds=False)
    connection.close()
"""

SWAYMSG = """
import os, socket, sys
args = sys.argv[1:]
path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-1"))
if args[:1] == ["--socket"]:
    path, args = args[1], args[2:]
client = socket.socket(socket.AF_UNIX)
try:
    client.connect(path)
except OSError:
    sys.exit(1)
client.sendall(" ".join(args).encode())
"""

HYPRLAND = """
import os, socket, time
server = socket.socket(socket.AF_UNIX)
server.bind(os.path.join(os.environ["XDG_RUNTIME_DIR"], "hyprland-1"))
server.listen()
time.sleep(3600)
"""

LISTEN = """
import socket, sys, time
port = int(sys.argv[sys.argv.index("--listen") + 1] if "--listen" in sys.argv else sys.argv[-1])
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen()
while True:
    server.accept()[0].close()
"""

STUBS = {
    "sway": SWAY,
    "swaymsg": SWAYMSG,
    "agent-sandbox-nested-hyprland": HYPRLAND,
    "wayvnc": LISTEN,
    "novnc": LISTEN,
}


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class SandboxDisplayTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.runtime = root / "run"
        self.runtime.mkdir()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in STUBS.items():
            stub = bin_dir / name
            stub.write_text(f"#!{sys.executable}\n{textwrap.dedent(body)}")
            stub.chmod(0o755)
        self.lock = self.runtime / "sandbox-display.lock"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "XDG_RUNTIME_DIR": str(self.runtime),
            "WAYLAND_DISPLAY": "wayland-1",
            "AGENT_SANDBOX_RENDERERS": "pixman",
            "SANDBOX_DISPLAY_VNC_PORT": str(free_port()),
            "SANDBOX_DISPLAY_NOVNC_PORT": str(free_port()),
        }

    def tearDown(self):
        for pid in self.daemons():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.directory.cleanup()

    def daemons(self):
        pids = []
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                environ = (proc / "environ").read_bytes()
            except OSError:
                continue
            if f"XDG_RUNTIME_DIR={self.runtime}".encode() in environ.split(b"\0"):
                pids.append(int(proc.name))
        return pids

    def lock_holders(self):
        holders = []
        for pid in self.daemons():
            try:
                fds = list(Path(f"/proc/{pid}/fd").iterdir())
            except OSError:
                continue
            for fd in fds:
                try:
                    if Path(os.readlink(fd)) == self.lock:
                        holders.append(pid)
                except OSError:
                    pass
        return holders

    def display(self, *args):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_hyprland_starts_after_sway(self):
        result = self.display("up")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("sway: up", result.stdout)
        time.sleep(0.5)
        self.assertEqual(self.lock_holders(), [])

        result = self.display("up", "--hyprland")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nested Hyprland: up", result.stdout)
        self.assertEqual(self.lock_holders(), [])

    def test_up_restarts_a_dead_wayvnc(self):
        result = self.display("up")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wayvnc: up", result.stdout)
        for pid in self.daemons():
            if b"wayvnc" in Path(f"/proc/{pid}/cmdline").read_bytes():
                os.kill(pid, signal.SIGKILL)
        time.sleep(0.3)
        self.assertIn("wayvnc: down", self.display("status").stdout)
        result = self.display("up")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("wayvnc: up", result.stdout)
        self.assertIn("noVNC: up", result.stdout)


if __name__ == "__main__":
    unittest.main()
