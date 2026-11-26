#!/usr/bin/env python3
"""Check which sandbox agent-sandbox-exec picks, without starting containers or Orca."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).with_name("agent-sandbox-exec.sh")


class SandboxAliasTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.launcher = self.home / "launcher"
        self.launcher.write_text('#!/bin/sh\necho "$AGENT_SANDBOX_NAME $PWD $*"\n')
        self.launcher.chmod(0o755)

    def launch(self, cwd, agent="claude", **extra):
        cwd.mkdir(parents=True, exist_ok=True)
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ORCA_", "GIT_")) and key not in ("CODEX_HOME", "CLAUDE_CONFIG_DIR")
        }
        env.update(HOME=str(self.home), AGENT_SANDBOX_LAUNCHER=str(self.launcher), **extra)
        return subprocess.run(
            ["bash", "-euo", "pipefail", str(WRAPPER), agent, "--flag"],
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def alias(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        name, cwd, *args = result.stdout.split()
        match = re.fullmatch(r"agent-sandbox-(.+)-h\d+-\d+", name)
        self.assertIsNotNone(match, name)
        return match.group(1), cwd, args

    def test_bot_home_outside_git_uses_its_own_sandbox(self):
        bot = self.home / ".orca/bots/elma"
        for agent in ("claude", "codex", "antigravity", "agy", "opencode"):
            with self.subTest(agent=agent):
                alias, cwd, args = self.alias(self.launch(bot, agent))
                self.assertEqual(alias, "sandbox-bot-elma")
                self.assertEqual(cwd, str(bot))
                self.assertEqual(args[-1], "--flag")

    def test_bot_subdirectory_keeps_the_bot_sandbox(self):
        alias, _, _ = self.alias(self.launch(self.home / ".orca/bots/kanna/memory"))
        self.assertEqual(alias, "sandbox-bot-kanna")

    def test_bot_sandbox_wins_over_chat_account(self):
        account = self.home / ".config/orca/codex-runtime-home/home"
        account.mkdir(parents=True)
        alias, _, _ = self.alias(self.launch(self.home / ".orca/bots/kanna", "codex", CODEX_HOME=str(account)))
        self.assertEqual(alias, "sandbox-bot-kanna")

    def test_chat_account_outside_bots_keeps_chat_sandbox(self):
        account = self.home / ".claude"
        alias, _, _ = self.alias(self.launch(account, CLAUDE_CONFIG_DIR=str(account)))
        self.assertEqual(alias, "sandbox-claude-chat")

    def test_bots_root_and_other_folders_still_need_git(self):
        for cwd in (self.home / ".orca/bots", self.home / "elsewhere"):
            with self.subTest(cwd=cwd):
                result = self.launch(cwd)
                self.assertEqual(result.returncode, 2)
                self.assertIn("inside a Git repository", result.stderr)

    def test_repository_uses_its_name(self):
        repo = self.home / ".orca/bots/tester/project"
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        alias, _, _ = self.alias(self.launch(repo))
        self.assertEqual(alias, "sandbox-project")

    def test_invalid_bot_name_is_refused(self):
        result = self.launch(self.home / ".orca/bots/bad name")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid sandbox alias", result.stderr)


if __name__ == "__main__":
    unittest.main()
