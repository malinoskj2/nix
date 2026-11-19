import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


SCRIPT = Path(__file__).with_name("prepare-orca-hooks.py")


class PrepareOrcaHooksTest(unittest.TestCase):
    def test_refreshes_managed_files_and_hashes_without_resetting_choices(self):
        with tempfile.TemporaryDirectory() as root:
            host = Path(root) / "host"
            sandbox = Path(root) / "sandbox"
            host_hooks = host / ".orca/agent-hooks"
            sandbox_hooks = sandbox / ".orca/agent-hooks"
            host_codex = host / ".config/orca/codex-runtime-home/home"
            sandbox_codex = sandbox / ".codex"
            for directory in (host_hooks, sandbox_hooks, host_codex, sandbox_codex):
                directory.mkdir(parents=True)

            host_key = f"{host_codex}/hooks.json:session_start:0:0"
            sandbox_key = f"{host}/.codex/hooks.json:session_start:0:0"
            (host_hooks / "claude-hook.sh").write_text("new script\n")
            (sandbox_hooks / "claude-hook.sh").write_text("old script\n")
            (host_hooks / "claude-settings.json").write_text('{"hooks":{"SessionStart":[]}}\n')
            (sandbox_hooks / "claude-settings.json").write_text('{"hooks":{}}\n')
            (host_codex / "hooks.json").write_text('{"hooks":{"session_start":[]}}\n')
            (sandbox_codex / "hooks.json").write_text('{"hooks":{}}\n')
            (host_codex / "config.toml").write_text(
                f'[hooks.state.{json.dumps(host_key)}]\ntrusted_hash = "sha256:new"\n'
            )
            original = (
                'model = "test"\n'
                f"[hooks.state.{json.dumps(sandbox_key)}]\n"
                'enabled = false\ntrusted_hash = "sha256:old"\n'
                '[projects."/work"]\ntrust_level = "trusted"\n'
            )
            (sandbox_codex / "config.toml").write_text(original)

            for _ in range(2):
                subprocess.run([sys.executable, SCRIPT, host, sandbox], check=True)

            self.assertEqual((sandbox_hooks / "claude-hook.sh").read_text(), "new script\n")
            self.assertEqual(
                (sandbox_hooks / "claude-settings.json").read_bytes(),
                (host_hooks / "claude-settings.json").read_bytes(),
            )
            self.assertEqual(
                (sandbox_codex / "hooks.json").read_bytes(),
                (host_codex / "hooks.json").read_bytes(),
            )
            config_text = (sandbox_codex / "config.toml").read_text()
            config = tomllib.loads(config_text)
            self.assertEqual(
                config["hooks"]["state"][sandbox_key],
                {
                    "enabled": False,
                    "trusted_hash": "sha256:new",
                },
            )
            self.assertEqual(config["projects"]["/work"]["trust_level"], "trusted")
            self.assertEqual(config_text.count(f"[hooks.state.{json.dumps(sandbox_key)}]"), 1)

    def test_antigravity_hooks_and_trust_reach_the_sandbox(self):
        with tempfile.TemporaryDirectory() as root:
            host = Path(root) / "host"
            sandbox = Path(root) / "sandbox"
            (host / ".orca/agent-hooks").mkdir(parents=True)
            (host / ".orca/agent-hooks/antigravity-hook.sh").write_text("hook\n")
            (host / ".gemini/config").mkdir(parents=True)
            (host / ".gemini/config/hooks.json").write_text('{"orca-status":{}}\n')
            host_settings = host / ".gemini/antigravity-cli/settings.json"
            host_settings.parent.mkdir(parents=True)
            host_settings.write_text('{"toolPermission":"always-proceed","trustedWorkspaces":["/a"]}\n')

            subprocess.run([sys.executable, SCRIPT, host, sandbox], check=True)
            sandbox_settings = sandbox / ".gemini/antigravity-cli/settings.json"
            self.assertEqual(sandbox_settings.read_bytes(), host_settings.read_bytes())
            self.assertEqual((sandbox / ".orca/agent-hooks/antigravity-hook.sh").read_text(), "hook\n")
            self.assertEqual((sandbox / ".gemini/config/hooks.json").read_text(), '{"orca-status":{}}\n')

            sandbox_settings.write_text('{"model":"m","trustedWorkspaces":["/b","/a"]}\n')
            host_settings.write_text('{"trustedWorkspaces":["/a","/c",3]}\n')
            for _ in range(2):
                subprocess.run([sys.executable, SCRIPT, host, sandbox], check=True)
            self.assertEqual(
                json.loads(sandbox_settings.read_text()),
                {"model": "m", "trustedWorkspaces": ["/b", "/a", "/c"]},
            )


if __name__ == "__main__":
    unittest.main()
