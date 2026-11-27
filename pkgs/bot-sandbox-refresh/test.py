#!/usr/bin/env python3
import os
from pathlib import Path
from socket import create_server
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)).resolve()
PREVIEW_PORTS = Path(sys.argv.pop(1)).resolve()
BASE = 47600

STUBS = {
    "docker": """#!/bin/sh
case "$1" in
  ps) printf 'agent-sandbox-sandbox-bot-elma-h1-2 old\\nagent-sandbox-sandbox-bot-ghost-h1-2 old\\n' ;;
  stop) shift; echo "$@" >>"$LOG/stops" ;;
esac
""",
    "orca": """#!/bin/sh
case "$1 $2" in
  "worktree ps") printf '{"result":{"worktrees":[{"path":"%s/elma","status":"idle","agents":[]},{"path":"%s/ghost","status":"idle","agents":[]}]}}' "$BOTS" "$BOTS" ;;
  "bot list") echo '{"result":{"bots":[{"name":"Elma"},{"name":"Kanna"}]}}' ;;
  "orchestration send") shift 2; printf '%s\\n' "$@" >"$LOG/send" ;;
esac
""",
    "ip": "#!/bin/sh\necho '1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.10 uid 1000'\n",
}


class Refresh(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "log"
        bin_dir = self.root / "bin"
        self.log.mkdir()
        bin_dir.mkdir()
        for name, body in STUBS.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        tool = bin_dir / "preview-ports"
        tool.write_text(f'#!/bin/sh\nexec bash {PREVIEW_PORTS} "$@"\n')
        tool.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "LOG": str(self.log),
            "BOTS": str(self.root / "bots"),
            "ORCA_CLI_COMMAND": "orca",
            "BOT_SANDBOX_REFRESH_BOTS": str(self.root / "bots"),
            "BOT_SANDBOX_REFRESH_PORT_WAIT": "0.01",
            "AGENT_SANDBOX_IMAGE_REF": "new",
            "AGENT_SANDBOX_PREVIEW_PORTS_TOOL": str(tool),
            "AGENT_SANDBOX_PREVIEW_STATE": str(self.root / "state"),
            "AGENT_SANDBOX_PREVIEW_BASE": str(BASE),
        }
        base = subprocess.run([str(tool), "bot:elma"], env=self.env, capture_output=True, text=True, check=True).stdout
        self.base = int(base)

    def refresh(self):
        result = subprocess.run(
            ["bash", "-euo", "pipefail", str(SCRIPT)], env=self.env, capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout, (self.log / "send").read_text().splitlines()

    def body(self, send):
        self.assertEqual(send[:6], ["--to", "bot:Elma", "--type", "status", "--subject", "Sandbox restarted"])
        return "\n".join(send[send.index("--body") + 1 :])

    def test_free_block_names_the_bots_urls(self):
        out, send = self.refresh()
        self.assertIn("notified elma", out)
        self.assertIn("notify ghost skipped", out)
        body = self.body(send)
        self.assertIn("/tmp are gone", body)
        for offset in range(5):
            self.assertIn(f"AGENT_PREVIEW_URL_{8080 + offset}: http://192.0.2.10:{self.base + offset}", body)

    def test_held_middle_port_defers_to_the_session(self):
        held = create_server(("127.0.0.1", self.base + 2))
        self.addCleanup(held.close)
        out, send = self.refresh()
        self.assertIn("notified elma", out)
        body = self.body(send)
        self.assertIn("/tmp are gone", body)
        self.assertIn("use AGENT_PREVIEW_URL_* there", body)
        self.assertNotIn(f":{self.base}", body)


if __name__ == "__main__":
    unittest.main()
