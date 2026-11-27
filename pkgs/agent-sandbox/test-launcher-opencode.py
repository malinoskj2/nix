#!/usr/bin/env python3
import os
from pathlib import Path
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
    "runner": "#!/bin/sh\nexit 0\n",
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
    "findmnt": "#!/bin/sh\nexit 1\n",
}


class LauncherOpenCode(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
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
        self.config = self.home / ".config/opencode"
        (self.config / "skills/example").mkdir(parents=True)
        (self.config / "skills/example/SKILL.md").write_text("---\nname: example\n---\n")
        (self.config / "opencode.json").write_text("{}\n")
        (self.config / "AGENTS.md").write_text("rules\n")
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
        }

    def launched(self, *args):
        result = subprocess.run(
            ["bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", str(self.script), *args],
            cwd=self.home,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = (self.log / "create").read_text().splitlines()
        volumes = {}
        for flag, value in zip(argv, argv[1:]):
            if flag == "--volume":
                source, target, *mode = value.split(":")
                volumes[target] = (source, mode == ["ro"])
        return argv, volumes

    def test_opencode_runs_plain_opencode(self):
        argv, _ = self.launched("--opencode", "--session", "abc")
        self.assertEqual(argv[-3:], ["opencode", "--session", "abc"])
        self.assertNotIn("qwen-opencode", argv)

    def test_host_opencode_config_is_mounted_read_only(self):
        _, volumes = self.launched("--opencode")
        for name in ("opencode.json", "AGENTS.md", "skills"):
            with self.subTest(name=name):
                path = str(self.config / name)
                self.assertEqual(volumes.get(path), (path, True))

    def test_opencode_data_stays_in_the_sandbox_home(self):
        _, volumes = self.launched("--opencode")
        self.assertNotIn(str(self.config), volumes)
        self.assertNotIn(str(self.home / ".local/share/opencode"), volumes)


if __name__ == "__main__":
    unittest.main()
