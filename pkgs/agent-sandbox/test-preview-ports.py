#!/usr/bin/env python3
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

TOOL = Path(__file__).with_name("agent-sandbox-preview-ports.sh")


class PreviewPorts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.state = self.root / "state/preview-ports"
        self.env = {**os.environ, "AGENT_SANDBOX_PREVIEW_STATE": str(self.state)}

    def allocate(self, identity, check=True, **env):
        result = subprocess.run(
            ["bash", "-euo", "pipefail", str(TOOL), identity],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            timeout=30,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return int(result.stdout)
        return result

    def test_same_identity_keeps_its_ports(self):
        first = self.allocate("bot:elma")
        self.allocate("bot:kanna")
        self.assertEqual(self.allocate("bot:elma"), first)
        self.assertEqual((first - 19000) % 5, 0)
        self.assertTrue(19000 <= first < 21000)

    def test_identities_never_share_a_slot(self):
        names = [f"sandbox-{n}" for n in range(60)] + ["bot:elma", "bot:kanna", "sandbox-codex-chat"]
        env = {"AGENT_SANDBOX_PREVIEW_SLOTS": "64"}
        bases = [self.allocate(name, **env) for name in names]
        self.assertEqual(len(set(bases)), len(names))
        self.assertEqual([self.allocate(name, **env) for name in names], bases)

    def test_collision_moves_to_the_next_slot_and_stays(self):
        env = {"AGENT_SANDBOX_PREVIEW_SLOTS": "1"}
        self.assertEqual(self.allocate("bot:a", **env), 19000)
        result = self.allocate("bot:b", check=False, **env)
        self.assertEqual(result.returncode, 1)
        env = {"AGENT_SANDBOX_PREVIEW_SLOTS": "2"}
        b = self.allocate("bot:b", **env)
        self.assertEqual(b, 19005)
        self.assertEqual(self.allocate("bot:a", **env), 19000)
        self.assertEqual(self.allocate("bot:b", **env), b)

    def test_concurrent_allocations_are_distinct(self):
        names = [f"bot:{n}" for n in range(16)]
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            bases = list(pool.map(self.allocate, names))
        self.assertEqual(len(set(bases)), len(names))
        self.assertEqual(len(self.state.read_text().splitlines()), len(names))

    def test_removed_worktree_gives_its_slot_back(self):
        worktree = self.root / "worktree"
        worktree.mkdir()
        env = {"AGENT_SANDBOX_PREVIEW_SLOTS": "1"}
        self.assertEqual(self.allocate(str(worktree), **env), 19000)
        worktree.rmdir()
        self.assertEqual(self.allocate("bot:elma", **env), 19000)

    def test_refuses_identities_that_would_break_the_file(self):
        for identity in ("", "a\tb", "a\nb"):
            self.assertEqual(self.allocate(identity, check=False).returncode, 2)


if __name__ == "__main__":
    unittest.main()
