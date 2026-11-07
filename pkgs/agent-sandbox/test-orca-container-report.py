#!/usr/bin/env python3
"""Exercise launcher exit reporting without starting containers or Orca."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).with_name("agent-sandbox-exec.sh")
ROOT = WRAPPER.parents[2]
CLEAR = b"\x1b]777;orca-container;clear\x1b\\"


class ContainerReportTest(unittest.TestCase):
    def launch(self, code, *, orca=True):
        with tempfile.TemporaryDirectory() as temporary:
            launcher = Path(temporary) / "launcher"
            launcher.write_text(f"#!/bin/sh\nexit {code}\n")
            launcher.chmod(0o755)
            env = {key: value for key, value in os.environ.items() if not key.startswith("ORCA_")}
            env["AGENT_SANDBOX_LAUNCHER"] = str(launcher)
            if orca:
                env["ORCA_PANE_KEY"] = "test-pane"
            return subprocess.run(
                ["bash", "-euo", "pipefail", str(WRAPPER), "claude"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                timeout=5,
                check=False,
            )

    def test_success_clears_only_this_terminal(self):
        result = self.launch(0)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stderr.endswith(CLEAR))
        self.assertNotIn(b"orca-container;name=", result.stdout + result.stderr)

    def test_failed_container_launch_preserves_failure_and_clears(self):
        result = self.launch(42)
        self.assertEqual(result.returncode, 42)
        self.assertTrue(result.stderr.endswith(CLEAR))

    def test_non_orca_launch_does_not_emit_reports(self):
        result = self.launch(0, orca=False)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(CLEAR, result.stderr)


if __name__ == "__main__":
    unittest.main()
