#!/usr/bin/env python3
"""Every container given the host nix-daemon socket runs as the launching user, never root.

nix-daemon trusts root, and Docker runs container root as host root, so a root process holding the
socket would be a trusted client. Sources that mount the socket must pass --user with the caller's
uid, and the launchers, runner and image entrypoint must exit as root before Docker runs.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(sys.argv.pop(1))


def fake_bin(directory, uid):
    bin_dir = Path(directory, "bin")
    bin_dir.mkdir()
    marker = Path(directory, "docker-ran")
    (bin_dir / "id").write_text(f'#!/bin/sh\ncase "$1" in -u|-g) echo {uid} ;; *) echo user ;; esac\n')
    (bin_dir / "docker").write_text(f"#!/bin/sh\ntouch {marker}\n")
    for tool in bin_dir.iterdir():
        tool.chmod(0o755)
    return bin_dir, marker


class Sources(unittest.TestCase):
    def test_socket_mounts_pass_the_callers_uid(self):
        mounting = []
        for path in sorted(ROOT.rglob("*")):
            if not path.is_file() or path.suffix not in (".sh", ".py") or path.name.startswith("test-"):
                continue
            text = path.read_text()
            if "/nix/var/nix/daemon-socket:" not in text:
                continue
            mounting.append(path.name)
            with self.subTest(path.name):
                self.assertRegex(text, r'"--user",?\s*\n?\s*f"\{(os\.getuid\(\)|uid)\}:|--user "\$uid:\$gid"')
                self.assertNotRegex(text, r'--user[ "=,\n]+(0|root)\b')
        self.assertEqual(sorted(mounting), ["agent-sandbox.sh", "runner.py"], "update this check")


class RefusesRoot(unittest.TestCase):
    def run_script(self, name, uid):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir, marker = fake_bin(directory, uid)
            env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": directory, "XDG_RUNTIME_DIR": directory}
            result = subprocess.run(
                ["bash", str(ROOT / name), "true"], env=env, capture_output=True, text=True, timeout=30
            )
            return result, marker.exists()

    def test_shell_entry_points_exit_before_docker(self):
        for name in ("agent-sandbox.sh", "agent-sandbox-codex-server.sh", "entrypoint.sh"):
            with self.subTest(name):
                result, docker_ran = self.run_script(name, 0)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing to", result.stderr)
                self.assertFalse(docker_ran)

    def test_runner_exits_before_starting(self):
        spec = importlib.util.spec_from_file_location("runner", ROOT / "runner/runner.py")
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        argv = ["--owner", "o", "--socket", "/nonexistent/s", "--state-dir", "/nonexistent/d", "--image", "i"]
        argv += ["--root", "/nonexistent", "--passwd", "p", "--group", "g", "--ports-lock", "l"]
        with (
            unittest.mock.patch.object(runner.os, "getuid", return_value=0),
            unittest.mock.patch.object(runner, "Runner", side_effect=AssertionError("started")),
        ):
            with self.assertRaises(SystemExit) as exit:
                runner.main(argv)
        self.assertIn("refusing to run as root", str(exit.exception))


if __name__ == "__main__":
    unittest.main()
