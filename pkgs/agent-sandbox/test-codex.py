#!/usr/bin/env python3
"""Check the sandbox codex wrapper's --cloud flag against a fake codex."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).parent / "codex.sh"


class Cloud(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.fake = Path(temporary.name) / "codex"
        self.fake.write_text('#!/bin/sh\nfor a; do echo "$a"; done\n')
        self.fake.chmod(0o755)

    def run_wrapper(self, *args):
        result = subprocess.run(
            ["bash", str(WRAPPER), *args],
            env={**os.environ, "CODEX": str(self.fake)},
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.splitlines()

    def test_default_leaves_feature_off(self):
        self.assertEqual(self.run_wrapper("resume", "--last"), ["resume", "--last"])

    def test_no_arguments(self):
        self.assertEqual(self.run_wrapper(), [])

    def test_cloud_enables_feature_and_is_stripped(self):
        self.assertEqual(
            self.run_wrapper("--dangerously-bypass-approvals-and-sandbox", "--cloud", "hi there"),
            ["--enable", "tui_multi_backend", "--dangerously-bypass-approvals-and-sandbox", "hi there"],
        )

    def test_after_double_dash_is_untouched(self):
        self.assertEqual(self.run_wrapper("exec", "--", "--cloud"), ["exec", "--", "--cloud"])


if __name__ == "__main__":
    unittest.main()
