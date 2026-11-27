#!/usr/bin/env python3
"""Check the mounts agent-sandbox gives a container, and that Git works within them.

Docker is a stub that records the `docker create` arguments. The read-only parts of ~/nix are
then made unwritable by permissions, which stand in for the mounts, and Git runs in a worktree.
"""

import os
from pathlib import Path
from socket import create_server
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).parent
LAUNCHER = HERE / "agent-sandbox.sh"

STUBS = {
    "docker": """#!/bin/sh
case "$1" in
  create) shift; printf '%s\\n' "$@" >"$STUB_LOG/create"; echo cid ;;
esac
exit 0
""",
    "runner": '#!/bin/sh\nprintf \'%s\\n\' "$@" >"$STUB_LOG/runner"\n',
    "ssh-keygen": """#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = -f ]; then touch "$2" "$2.pub"; fi
  shift
done
""",
    "orca-relay": f"""#!{sys.executable}
import socket, sys, time
data = sys.argv[sys.argv.index("--data") + 1]
listener = socket.socket(socket.AF_UNIX)
listener.bind(data + "/relay.sock")
time.sleep(600)
""",
    "systemctl": "#!/bin/sh\nexit 0\n",
    "systemd-inhibit": "#!/bin/sh\nexit 0\n",
    "ip": "#!/bin/sh\nexit 0\n",
    "findmnt": """#!/bin/sh
case " $* " in
  *" -M "*) [ -n "${FINDMNT_TYPES:-}" ] && printf '%b\\n' "$FINDMNT_TYPES" && exit 0 ;;
esac
exit 1
""",
}

GIT_ENV = {
    "GIT_AUTHOR_NAME": "test",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_NOSYSTEM": "1",
}


class LauncherMounts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.cleanup, temporary)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.log = self.root / "log"
        bin_dir = self.root / "bin"
        for directory in (self.home, self.log, bin_dir, self.root / "run"):
            directory.mkdir()
        for name, body in STUBS.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        script = LAUNCHER.read_text().replace("runtime=/run/user/$uid", f"runtime={self.root}/run")
        self.script = self.root / "agent-sandbox.sh"
        self.script.write_text(script)
        self.env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "STUB_LOG": str(self.log),
            "AGENT_SANDBOX_TAG": "hash-test",
            "AGENT_SANDBOX_IMAGE": "true",
            "AGENT_SANDBOX_RUNNER": str(bin_dir / "runner"),
            "AGENT_SANDBOX_SECCOMP": "/dev/null",
            "AGENT_SANDBOX_INSTRUCTIONS": "/dev/null",
            "AGENT_SANDBOX_ORCA_PATH": "/usr/bin",
            "AGENT_SANDBOX_ORCA_RELAY": str(bin_dir / "orca-relay"),
            "AGENT_SANDBOX_EGRESS_LIB": str(LAUNCHER.with_name("egress.sh")),
            "AGENT_SANDBOX_EGRESS_CONFIG": str(self.root / "no-egress.json"),
            **GIT_ENV,
        }
        self.nix = self.home / "nix"
        self.git("init", "-q", "-b", "main", str(self.nix))
        self.git("-C", str(self.nix), "commit", "-q", "--allow-empty", "-m", "base")
        self.git("-C", str(self.nix), "branch", "fix/packed")
        self.origin = self.root / "origin.git"
        self.git("init", "-q", "--bare", str(self.origin))
        self.git("-C", str(self.nix), "remote", "add", "origin", str(self.origin))
        self.git("-C", str(self.nix), "push", "-q", "origin", "main", "main:gone")
        self.git("-C", str(self.nix), "fetch", "-q", "origin")
        self.git("-C", str(self.nix), "pack-refs", "--all")
        self.git("-C", str(self.nix), "update-ref", "refs/heads/main", "HEAD")
        self.worktree = self.home / "orca/workspaces/nix/feature"
        self.git("-C", str(self.nix), "worktree", "add", "-q", "-b", "malinoskj2/feature", str(self.worktree))
        self.git("-C", str(self.nix), "tag", "base")
        self.tohru = self.home / ".orca/bots/tohru"
        self.tohru.mkdir(parents=True)
        (self.tohru / "SOUL.md").write_text("soul\n")
        (self.home / ".orca/bots/elma").mkdir()

    def cleanup(self, temporary):
        for path, dirs, _ in os.walk(self.root):
            for name in dirs:
                Path(path, name).chmod(0o755)
        temporary.cleanup()

    def git(self, *args, cwd=None, check=True):
        return subprocess.run(
            ["git", *args], cwd=cwd, env={**os.environ, **GIT_ENV}, capture_output=True, text=True, check=check
        )

    def launch(self, *args, env=None):
        result = subprocess.run(
            ["bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", str(self.script), *args],
            cwd=self.worktree,
            env={**self.env, **(env or {})},
            capture_output=True,
            text=True,
            timeout=60,
        )
        return result

    def volumes(self):
        argv = (self.log / "create").read_text().splitlines()
        volumes = {}
        for flag, value in zip(argv, argv[1:]):
            if flag == "--volume":
                source, target, *mode = value.split(":")
                volumes[target] = (source, mode == ["ro"])
        return argv, volumes

    def launched(self, *args, env=None):
        result = self.launch(*args, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.volumes()

    def test_no_host_display_or_mirrors(self):
        argv, _ = self.launched()
        joined = "\n".join(argv)
        for needle in ("host-wayland", "host-clipboard", "/tmp/screenshot", "tohru-screens"):
            self.assertNotIn(needle, joined)

    def test_nix_is_read_only_but_worktree_git_is_writable(self):
        _, volumes = self.launched()
        git = self.nix / ".git"
        self.assertEqual(volumes[str(self.nix)], (str(self.nix), True))
        writable = sorted(
            target for target, (_, readonly) in volumes.items() if target.startswith(f"{self.nix}/") and not readonly
        )
        expected = [
            git / "logs",
            git / "objects",
            git / "refs/heads/fix",
            git / "refs/heads/malinoskj2",
            git / "refs/remotes",
            git / "refs/tags",
            git / "worktrees",
        ]
        self.assertEqual(writable, sorted(map(str, expected)))

    def test_symlinked_ref_prefix_is_not_mounted(self):
        (self.nix / ".git/refs/heads/evil").symlink_to("../..")
        _, volumes = self.launched()
        self.assertFalse(any("evil" in target for target in volumes))

    def test_tohru_is_read_only_and_other_bots_writable(self):
        _, volumes = self.launched()
        self.assertEqual(volumes[str(self.tohru)], (str(self.tohru), True))
        self.assertEqual(volumes[str(self.home / ".orca/bots")], (str(self.home / ".orca/bots"), False))
        runner = (self.log / "runner").read_text().splitlines()
        roots = [value for flag, value in zip(runner, runner[1:]) if flag == "--root"]
        denied = [value for flag, value in zip(runner, runner[1:]) if flag == "--deny"]
        self.assertNotIn(str(self.nix), roots)
        self.assertEqual(denied, [str(self.tohru)])

    def test_only_this_launchs_hook_bridge_is_mounted(self):
        shared = self.root / "run/agent-sandbox-orca"
        own = shared / "session.mine"
        (shared / "session.other").mkdir(parents=True)
        own.mkdir()
        _, volumes = self.launched(env={"ORCA_AGENT_HOOK_SOCKET": f"{own}/hook.sock"})
        self.assertEqual(volumes[str(own)], (str(own), False))
        self.assertNotIn(str(shared), volumes)
        self.assertFalse(any("session.other" in target for target in volumes))
        _, volumes = self.launched()
        self.assertFalse(any("agent-sandbox-orca/" in target or target == str(shared) for target in volumes))

    def test_refuses_a_hook_socket_outside_its_bridge(self):
        shared = self.root / "run/agent-sandbox-orca"
        (shared / "session.mine").mkdir(parents=True)
        (shared / "session.link").symlink_to(self.home)
        for socket in (
            f"{shared}/hook.sock",
            f"{shared}/session.mine/../session.mine/hook.sock",
            f"{shared}/session.link/hook.sock",
            f"{self.home}/hook.sock",
        ):
            with self.subTest(socket=socket):
                result = self.launch(env={"ORCA_AGENT_HOOK_SOCKET": socket})
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("refusing Orca hook socket", result.stderr)

    def test_refuses_a_symlinked_tohru_home(self):
        self.tohru.rename(self.home / ".orca/bots/real")
        self.tohru.symlink_to("real")
        result = self.launch()
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.log / "create").exists())

    def test_refuses_account_homes_in_protected_directories(self):
        for directory in (self.tohru, self.nix / ".git"):
            with self.subTest(directory=directory):
                result = self.launch("--codex", env={"CODEX_HOME": str(directory)})
                self.assertEqual(result.returncode, 2)
                self.assertFalse((self.log / "create").exists())

    def model_stores(self, **env):
        local, mounted = self.root / "stores/local", self.root / "stores/mounted"
        local.mkdir(parents=True, exist_ok=True)
        mounted.mkdir(exist_ok=True)
        config = self.home / ".config/local-models"
        config.mkdir(parents=True, exist_ok=True)
        (config / "stores").write_text(f"{local}\n{mounted}\n")
        (config / "mounted-stores").write_text(f"{mounted}\n")
        _, volumes = self.launched(env=env)
        return str(local) in volumes, str(mounted) in volumes

    def test_mounted_model_store_is_bound_only_while_mounted(self):
        self.assertEqual(self.model_stores(), (True, False))
        self.assertEqual(self.model_stores(FINDMNT_TYPES="autofs"), (True, False))
        self.assertEqual(self.model_stores(FINDMNT_TYPES="autofs\\nnfs4"), (True, True))

    def preview_urls(self, identity, **env):
        tool = self.root / "bin/preview-ports"
        tool.write_text(f'#!/bin/sh\nexec bash {HERE / "agent-sandbox-preview-ports.sh"} "$@"\n')
        tool.chmod(0o755)
        env = {
            "AGENT_SANDBOX_PREVIEW_PORTS_TOOL": str(tool),
            "AGENT_SANDBOX_PREVIEW_BASE": "47100",
            "AGENT_SANDBOX_IDENTITY": identity,
            **env,
        }
        argv, _ = self.launched(env=env)
        return [value.split("=", 1)[1] for value in argv if value.startswith("AGENT_PREVIEW_URL_")]

    def test_preview_ports_stay_with_the_identity(self):
        first = self.preview_urls("bot:elma")
        ports = [int(url.rsplit(":", 1)[1]) for url in first]
        self.assertEqual(ports, list(range(ports[0], ports[0] + 5)))
        self.assertTrue(47100 <= ports[0] < 49100)
        other = self.preview_urls("bot:kanna")
        self.assertEqual(self.preview_urls("bot:elma"), first)
        self.assertFalse(set(first) & set(other))

    def test_preview_ports_in_use_fall_back_to_a_search(self):
        first = self.preview_urls("bot:elma")
        held = create_server(("127.0.0.1", int(first[2].rsplit(":", 1)[1])))
        self.addCleanup(held.close)
        fallback = self.preview_urls("bot:elma")
        self.assertNotEqual(fallback, first)
        self.assertTrue(all(18080 <= int(url.rsplit(":", 1)[1]) < 47100 for url in fallback))
        held.close()
        self.assertEqual(self.preview_urls("bot:elma"), first)

    def test_git_within_the_mounts(self):
        _, volumes = self.launched()
        writable = {
            Path(target)
            for target, (_, readonly) in volumes.items()
            if target.startswith(f"{self.nix}/") and not readonly
        }
        for path, dirs, files in os.walk(self.nix):
            if any(Path(path) == target or target in Path(path).parents for target in writable):
                continue
            for name in files:
                file = Path(path, name)
                file.chmod(file.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
            Path(path).chmod(0o555)
        cwd = self.worktree
        (cwd / "file").write_text("change\n")
        for args in (
            ("add", "file"),
            ("commit", "-q", "-m", "change"),
            ("branch", "malinoskj2/other"),
            ("branch", "fix/other"),
            ("rebase", "-q", "main"),
            ("tag", "worker"),
            ("fetch", "-q", "origin"),
            ("worktree", "list"),
        ):
            with self.subTest(allowed=args):
                result = self.git(*args, cwd=cwd, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
        main = self.git("rev-parse", "main", cwd=cwd).stdout
        for args in (
            ("update-ref", "refs/heads/main", "HEAD"),
            ("branch", "toplevel"),
            ("config", "core.fsmonitor", "true"),
            ("config", "hook.x.command", "true"),
        ):
            with self.subTest(refused=args):
                self.assertNotEqual(self.git(*args, cwd=cwd, check=False).returncode, 0)
        self.assertEqual(self.git("rev-parse", "main", cwd=cwd).stdout, main)
        # Pruning deletes refs, and deleting any ref rewrites packed-refs, which stays read-only
        # so main can't be moved through it; the host prunes instead.
        self.git("-C", str(self.origin), "branch", "-D", "gone")
        self.assertNotEqual(self.git("fetch", "-q", "--prune", "origin", cwd=cwd, check=False).returncode, 0)
        self.assertEqual(self.git("fetch", "-q", "origin", cwd=cwd, check=False).returncode, 0)
        self.assertEqual(self.git("rev-parse", "main", cwd=cwd).stdout, main)
        with self.assertRaises(PermissionError):
            (self.nix / ".git/hooks/pre-commit").write_text("#!/bin/sh\n")
        with self.assertRaises(PermissionError):
            (self.nix / ".tmp").mkdir()


if __name__ == "__main__":
    unittest.main(argv=sys.argv)
