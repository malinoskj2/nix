import argparse
import importlib.util
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
EGRESS = HERE / "egress.sh"
KILL = HERE / "agent-sandbox-kill.sh"


def load_runner():
    spec = importlib.util.spec_from_file_location("runner", HERE / "runner" / "runner.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode()
    except OSError:
        return ""


def alive(pid):
    try:
        state = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0]
    except OSError:
        return False
    return state != "Z"


class IngressTest(unittest.TestCase):
    def setUp(self):
        if shutil.which("socat") is None:
            self.skipTest("socat isn't installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name) / "data" / "agent-sandbox"
        self.runtime = Path(self.tmp.name) / "runtime"
        self.pids = []
        self.addCleanup(self.stop)

    def stop(self):
        for pid in self.pids:
            try:
                os.kill(pid, 9)
            except OSError:
                pass

    def long_dir(self, root):
        """An ingress directory whose socket paths pass the 108-byte limit."""
        directory = root / ("x" * 60) / ("y" * 60)
        directory.mkdir(parents=True)
        self.assertGreater(len(str(directory / "8080.sock")), 108)
        return directory

    def backend(self, directory):
        server = socket.socket(socket.AF_UNIX)
        here = os.getcwd()
        os.chdir(directory)
        try:
            server.bind("8080.sock")
        finally:
            os.chdir(here)
        server.listen()
        server.settimeout(5)
        self.addCleanup(server.close)
        return server

    def exchange(self, port, server):
        deadline = time.monotonic() + 5
        while True:
            try:
                client = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.05)
        conn, _ = server.accept()
        client.sendall(b"ping")
        self.assertEqual(conn.recv(4), b"ping")
        client.close()
        conn.close()

    def launcher_forwarder(self, directory, port):
        script = f'source {EGRESS}; ingress_forward 127.0.0.1 {port} "$1" 8080; echo $!'
        pid = int(
            subprocess.run(
                ["bash", "-c", script, "-", str(directory)], capture_output=True, text=True, check=True
            ).stdout
        )
        self.pids.append(pid)
        return pid

    def runner_forwarder(self, directory, port):
        runner = load_runner()
        r = object.__new__(runner.Runner)
        r.args = argparse.Namespace(socat=shutil.which("socat"), preview_address="192.0.2.7")
        r.owner = "owner"
        r.egress_subnets = lambda: []
        state = {"ingress": directory, "forwarders": []}
        r.sandboxes = {"n": {"egress": state}}
        r.gate = lambda request: {"ok": True, "dir": "/gate/sandbox/n"}
        r.ingress("n", ["--publish", f"{port}:8080"])
        pid = state["forwarders"][0].pid
        self.pids.append(pid)
        return pid

    def kill_forwarders(self):
        """Run agent-sandbox-kill's forwarder lines, as after a launcher or runner died hard."""
        lines = [
            line
            for line in KILL.read_text().splitlines()
            if re.match(r"pkill -f -- .*(agent-sandbox-ingress|UNIX-CONNECT)", line)
        ]
        self.assertTrue(lines)
        subprocess.run(
            ["bash", "-c", "\n".join(lines)],
            env={**os.environ, "data": str(self.data), "runtime": str(self.runtime)},
            check=True,
        )

    def test_forwarders_reach_sockets_under_long_paths(self):
        launcher_dir = self.long_dir(self.runtime / "agent-sandbox-ingress")
        runner_dir = self.long_dir(self.data / "runner")
        for start, directory in ((self.launcher_forwarder, launcher_dir), (self.runner_forwarder, runner_dir)):
            server = self.backend(directory)
            port = free_port()
            pid = start(directory, port)
            self.exchange(port, server)
            self.assertTrue(cmdline(pid).startswith(f"agent-sandbox-ingress {directory} "), cmdline(pid))

    def test_agent_sandbox_kill_stops_orphaned_forwarders_only(self):
        launcher = self.launcher_forwarder(self.long_dir(self.runtime / "agent-sandbox-ingress"), free_port())
        runner = self.runner_forwarder(self.long_dir(self.data / "runner"), free_port())
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        other = self.launcher_forwarder(elsewhere, free_port())
        time.sleep(0.3)
        self.kill_forwarders()
        deadline = time.monotonic() + 5
        while (alive(launcher) or alive(runner)) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(launcher))
        self.assertFalse(alive(runner))
        self.assertTrue(alive(other), "a forwarder outside this home's sandbox directories is left alone")


if __name__ == "__main__":
    unittest.main()
