"""Regression coverage for native migration boundaries, without contacting Orca."""

import unittest
from unittest.mock import patch

from reconcile import OrcaError, reconcile_bases, reconcile_plugins


class PluginMigration(unittest.TestCase):
    def test_identity_consent_and_idempotence(self):
        desired = {"chron0.discord-presence": "/nix/store/pinned/discord"}
        request = {
            "code": "approval_required",
            "data": {"pluginKey": "chron0.discord-presence", "approvalFingerprint": "ap1-exact"},
        }
        with patch("reconcile.call", side_effect=[{"plugins": []}, OrcaError(request), {}]) as cli:
            reconcile_plugins("orca", desired)
            self.assertEqual(
                cli.call_args.args,
                ("orca", "plugin", "install", desired["chron0.discord-presence"], "--approve", "ap1-exact"),
            )
        installed = {
            "pluginKey": "chron0.discord-presence",
            "source": {"kind": "local-path", "reference": desired["chron0.discord-presence"]},
        }
        with patch("reconcile.call", return_value={"plugins": [installed]}) as cli:
            reconcile_plugins("orca", desired)
            self.assertEqual(cli.call_count, 1)

    def test_disabled_and_development_overrides_are_untouched(self):
        plugins = [
            {"pluginKey": "chron0.discord-presence", "status": "disabled"},
            {"pluginKey": "etherll.usage-insights", "isDev": True},
        ]
        with patch("reconcile.call", return_value={"plugins": plugins}) as cli:
            reconcile_plugins("orca", {p["pluginKey"]: "/new/store/path" for p in plugins})
            self.assertEqual(cli.call_count, 1)

    def test_never_approves_another_identity(self):
        request = {
            "code": "approval_required",
            "data": {"pluginKey": "other.plugin", "approvalFingerprint": "ap1-other"},
        }
        with patch("reconcile.call", side_effect=[{"plugins": []}, OrcaError(request)]) as cli:
            with self.assertRaises(OrcaError):
                reconcile_plugins("orca", {"etherll.usage-insights": "/store/usage"})
            self.assertEqual(cli.call_count, 2)

    def test_runtime_failure_propagates_for_timer_retry(self):
        with patch("reconcile.call", side_effect=OrcaError({"code": "runtime_unavailable"})):
            with self.assertRaises(OrcaError):
                reconcile_plugins("orca", {"etherll.usage-insights": "/store/usage"})


class BaseMigration(unittest.TestCase):
    def test_only_unset_local_declared_repo_is_seeded_once(self):
        repos = [
            {"id": "nix", "path": "/home/jesse/nix"},
            {"id": "custom", "path": "/custom", "worktreeBaseRef": "release"},
            {"id": "remote", "path": "/home/jesse/nix", "connectionId": "ssh:mac"},
            {"id": "runtime", "path": "/home/jesse/nix", "executionHostId": "runtime:server"},
            {"id": "other", "path": "/other"},
        ]
        initialized = set()
        with (
            patch("reconcile.call", side_effect=[{"repos": repos}, {"repo": repos[0]}, {}]) as cli,
            patch("reconcile.subprocess.run") as git,
        ):
            git.return_value.returncode = 0
            reconcile_bases("orca", {"/home/jesse/nix": "main", "/custom": "main"}, initialized)
            self.assertEqual(cli.call_count, 3)
            self.assertEqual(cli.call_args.args[-4:], ("--repo", "id:nix", "--ref", "main"))
        self.assertEqual(initialized, {"nix", "custom"})
        with patch("reconcile.call", return_value={"repos": repos}) as cli:
            reconcile_bases("orca", {"/home/jesse/nix": "main", "/custom": "main"}, initialized)
            self.assertEqual(cli.call_count, 1)

    def test_recheck_preserves_a_concurrent_custom_choice(self):
        repos = [{"id": "nix", "path": "/home/jesse/nix"}]
        with (
            patch("reconcile.call", side_effect=[{"repos": repos}, {"repo": {"worktreeBaseRef": "release"}}]) as cli,
            patch("reconcile.subprocess.run") as git,
        ):
            git.return_value.returncode = 0
            reconcile_bases("orca", {"/home/jesse/nix": "main"}, set())
            self.assertEqual(cli.call_count, 2)


if __name__ == "__main__":
    unittest.main()
