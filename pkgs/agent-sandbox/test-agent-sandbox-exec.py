#!/usr/bin/env python3
"""Check where agent-sandbox-exec and agent-sandbox-resume run an agent, without containers or Orca."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

HERE = Path(__file__).parent
EXEC = HERE / "agent-sandbox-exec.sh"
RESUME = HERE / "agent-sandbox-resume.sh"
BOT_HOME = HERE / "agent-sandbox-bot-home.sh"
TOHRU = "3001d2e5-f2ec-4efc-965d-7be4b9e99e02"


def git_init(path):
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    return path


class Harness(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve()
        self.bots = self.home / ".orca/bots"
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.script("agent-sandbox-bot-home", f'exec bash "{BOT_HOME}"')
        self.launcher = self.script("launcher", 'echo "$AGENT_SANDBOX_NAME $PWD $*"')

    def script(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)
        return path

    def bot(self, name, bot_id=None):
        home = self.bots / name
        home.mkdir(parents=True, exist_ok=True)
        if bot_id:
            (home / "bot.json").write_text(json.dumps({"id": bot_id, "name": name}))
        return home

    def run_script(self, script, cwd, *args, **extra):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ORCA_", "GIT_", "AGENT_SANDBOX_"))
            and key not in ("CODEX_HOME", "CLAUDE_CONFIG_DIR")
        }
        env.update(
            HOME=str(self.home),
            PWD=str(cwd),
            PATH=f"{self.bin}:{env['PATH']}",
            AGENT_SANDBOX_LAUNCHER=str(self.launcher),
            **extra,
        )
        return subprocess.run(
            ["bash", "-euo", "pipefail", str(script), *args],
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )


class SandboxAliasTest(Harness):
    def launch(self, cwd, agent="claude", **extra):
        if not cwd.exists():
            cwd.mkdir(parents=True)
        return self.run_script(EXEC, cwd, agent, "--flag", **extra)

    def alias(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        name, cwd, *args = result.stdout.split()
        match = re.fullmatch(r"agent-sandbox-(.+)-h\d+-\d+", name)
        self.assertIsNotNone(match, name)
        return match.group(1), cwd, args

    def test_bot_home_outside_git_uses_its_own_sandbox(self):
        bot = self.bot("elma")
        for agent in ("claude", "codex", "antigravity", "agy", "opencode"):
            with self.subTest(agent=agent):
                alias, cwd, args = self.alias(self.launch(bot, agent))
                self.assertEqual(alias, "sandbox-bot-elma")
                self.assertEqual(cwd, str(bot))
                self.assertEqual(args[-1], "--flag")

    def test_bot_subdirectory_keeps_the_bot_sandbox(self):
        alias, _, _ = self.alias(self.launch(self.bots / "kanna/memory"))
        self.assertEqual(alias, "sandbox-bot-kanna")

    def test_bot_sandbox_wins_over_chat_account(self):
        account = self.home / ".config/orca/codex-runtime-home/home"
        account.mkdir(parents=True)
        alias, _, _ = self.alias(self.launch(self.bot("kanna"), "codex", CODEX_HOME=str(account)))
        self.assertEqual(alias, "sandbox-bot-kanna")

    def test_chat_account_outside_bots_keeps_chat_sandbox(self):
        account = self.home / ".claude"
        alias, _, _ = self.alias(self.launch(account, CLAUDE_CONFIG_DIR=str(account)))
        self.assertEqual(alias, "sandbox-claude-chat")

    def test_bots_root_and_other_folders_still_need_git(self):
        for cwd in (self.bots, self.home / "elsewhere"):
            with self.subTest(cwd=cwd):
                result = self.launch(cwd)
                self.assertEqual(result.returncode, 2)
                self.assertIn("inside a Git repository", result.stderr)

    def test_repository_uses_its_name(self):
        repo = git_init(self.bots / "tester/project")
        alias, _, _ = self.alias(self.launch(repo))
        self.assertEqual(alias, "sandbox-project")

    def test_invalid_bot_name_is_refused(self):
        result = self.launch(self.bots / "bad name")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid sandbox alias", result.stderr)

    def test_symlink_into_a_bot_home_starts_in_its_mounted_path(self):
        bot = self.bot("kanna")
        (bot / "memory").mkdir()
        (self.home / "alias").symlink_to(bot)
        alias, cwd, _ = self.alias(self.launch(self.home / "alias/memory"))
        self.assertEqual(alias, "sandbox-bot-kanna")
        self.assertEqual(cwd, str(bot / "memory"))

    def test_symlinked_bots_root_starts_under_its_mount(self):
        real = self.home / "real-bots"
        (real / "kanna").mkdir(parents=True)
        self.bots.parent.mkdir(parents=True)
        self.bots.symlink_to(real)
        alias, cwd, _ = self.alias(self.launch(self.bots / "kanna", "codex", CODEX_HOME=str(self.home)))
        self.assertEqual(alias, "sandbox-bot-kanna")
        self.assertEqual(cwd, str(self.bots / "kanna"))

    def test_symlink_out_of_a_bot_home_is_refused(self):
        outside = self.home / "outside"
        outside.mkdir()
        (self.bot("kanna") / "outside").symlink_to(outside)
        result = self.launch(self.bots / "kanna/outside", "codex", CODEX_HOME=str(self.home))
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_symlink_into_a_bot_repository_starts_in_its_mounted_path(self):
        repo = git_init(self.bot("kanna") / "project")
        (self.home / "alias").symlink_to(self.bots / "kanna")
        alias, cwd, _ = self.alias(self.launch(self.home / "alias/project"))
        self.assertEqual(alias, "sandbox-project")
        self.assertEqual(cwd, str(repo))

    def test_symlink_out_of_a_bot_home_into_a_repository_is_refused(self):
        outside = git_init(self.home / "outside")
        (self.bot("kanna") / "outside").symlink_to(outside)
        result = self.launch(self.bots / "kanna/outside")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")


class ResumeTest(Harness):
    def setUp(self):
        super().setUp()
        self.script("agent-sandbox-exec", 'echo "sandbox $PWD $*"')
        for agent in ("claude", "codex", "agy"):
            self.script(agent, f'echo "host $PWD {agent} $*"')
        self.account = self.home / "codex-account"
        sessions = self.account / "sessions/2026/11/26"
        sessions.mkdir(parents=True)
        (sessions / "rollout-test-abc.jsonl").write_text("{}\n")

    def resume(self, cwd, agent, *args, **extra):
        extra.setdefault("AGENT_SANDBOX_HOST_BOT_IDS", TOHRU)
        return self.run_script(RESUME, cwd, agent, *args, **extra)

    def where(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        place, cwd, *args = result.stdout.split()
        return place, cwd, args

    def test_bot_codex_with_its_account_resumes_in_the_sandbox(self):
        bot = self.bot("kanna", "8db85289-0c24-4efe-9efc-d36b1a386a2a")
        result = self.resume(
            bot, "codex", "--dangerously-bypass-approvals-and-sandbox", "resume", "abc", CODEX_HOME=str(self.account)
        )
        self.assertEqual(self.where(result), ("sandbox", str(bot), ["codex", "resume", "abc"]))

    def test_every_bot_agent_resumes_in_the_sandbox(self):
        bot = self.bot("elma", "2e1e0e3b-cc2b-4ec2-9d72-ab35480ba809")
        for agent in ("claude", "codex", "antigravity"):
            with self.subTest(agent=agent):
                place, cwd, _ = self.where(self.resume(bot, agent, "--resume", "unknown"))
                self.assertEqual((place, cwd), ("sandbox", str(bot)))

    def test_bot_without_a_readable_id_stays_in_the_sandbox(self):
        bot = self.bot("chad")
        (bot / "bot.json").write_text("not json")
        place, _, _ = self.where(self.resume(bot, "codex", "resume", "abc", CODEX_HOME=str(self.account)))
        self.assertEqual(place, "sandbox")

    def test_host_bot_resumes_on_the_host(self):
        bot = self.bot("tohru", TOHRU)
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                place, _, args = self.where(self.resume(bot, agent, "--resume", "abc", CODEX_HOME=str(self.account)))
                self.assertEqual((place, args[0]), ("host", agent))

    def test_host_bot_ids_come_from_the_environment(self):
        bot = self.bot("tohru", TOHRU)
        place, _, _ = self.where(self.resume(bot, "claude", "--resume", "abc", AGENT_SANDBOX_HOST_BOT_IDS=""))
        self.assertEqual(place, "sandbox")

    def test_symlink_into_a_bot_home_resumes_in_the_sandbox(self):
        bot = self.bot("kanna", "8db85289-0c24-4efe-9efc-d36b1a386a2a")
        (self.home / "alias").symlink_to(bot)
        result = self.resume(self.home / "alias", "codex", "resume", "abc", CODEX_HOME=str(self.account))
        self.assertEqual(self.where(result)[:2], ("sandbox", str(bot)))

    def test_symlink_out_of_a_bot_home_runs_nowhere(self):
        outside = self.home / "outside"
        outside.mkdir()
        (self.bot("kanna", "8db85289-0c24-4efe-9efc-d36b1a386a2a") / "outside").symlink_to(outside)
        result = self.resume(self.bots / "kanna/outside", "codex", "resume", "abc", CODEX_HOME=str(self.account))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_host_bot_in_a_repository_resumes_on_the_host(self):
        bot = self.bot("tohru", TOHRU)
        for cwd in (git_init(bot / "project"), git_init(bot)):
            for agent in ("claude", "codex", "antigravity"):
                with self.subTest(cwd=cwd, agent=agent):
                    place, _, args = self.where(self.resume(cwd, agent, "--resume", "abc"))
                    self.assertEqual((place, args[0]), ("host", "agy" if agent == "antigravity" else agent))

    def test_bot_repository_through_a_symlink_resumes_from_its_mounted_path(self):
        repo = git_init(self.bot("kanna", "8db85289-0c24-4efe-9efc-d36b1a386a2a") / "project")
        (self.home / "alias").symlink_to(self.bots / "kanna")
        result = self.resume(self.home / "alias/project", "codex", "resume", "abc", CODEX_HOME=str(self.account))
        self.assertEqual(self.where(result)[:2], ("sandbox", str(repo)))

    def test_symlink_out_of_a_bot_home_into_a_repository_runs_nowhere(self):
        outside = git_init(self.home / "outside")
        (self.bot("kanna", "8db85289-0c24-4efe-9efc-d36b1a386a2a") / "outside").symlink_to(outside)
        result = self.resume(self.bots / "kanna/outside", "claude", "--resume", "abc")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_other_folders_outside_git_resume_on_the_host(self):
        other = self.home / "other"
        other.mkdir()
        place, _, _ = self.where(self.resume(other, "claude", "--resume", "abc"))
        self.assertEqual(place, "host")


if __name__ == "__main__":
    unittest.main()
