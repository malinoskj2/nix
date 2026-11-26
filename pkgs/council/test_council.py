import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

COUNCIL = Path(__file__).with_name("council.py")

RECORD = """import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
stdin = '' if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read()
Path(os.environ['CAPTURE'], name + '.json').write_text(json.dumps({'argv': sys.argv[1:], 'stdin': stdin, 'claudecode': os.environ.get('CLAUDECODE')}))
"""

FAKES = {
    "codex": RECORD
    + """argv = sys.argv[1:]
Path(argv[argv.index('-o') + 1]).write_text('codex finding')
print('codex progress noise')
""",
    "claude": RECORD + "print('claude finding')\n",
    "agy": RECORD
    + "print(json.dumps({'event': 'result', 'result': {'status': 'SUCCESS', 'response': 'gemini finding'}}))\n",
}


def agy_stream(text, sleep=0):
    return (
        RECORD
        + "import time\n"
        + f"print(json.dumps({{'event': 'step_update', 'step_update': {{'step_index': 3, 'step_type': 'agent_response', 'text_delta': {text!r}}}}}), flush=True)\n"
        + f"time.sleep({sleep})\n"
    )


def alive(pid):
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except FileNotFoundError:
        return False
    return state != "Z"


class CouncilTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.capture = self.root / "capture"
        self.bin.mkdir()
        self.capture.mkdir()
        self.prompt = self.root / "prompt.txt"
        self.prompt.write_text('Review $(touch SHOULD_NOT_EXIST) "this" λ\n')
        self.context = self.root / "diff.patch"
        self.context.write_text("--- a\n+++ b\n")

    def tearDown(self):
        self.tmp.cleanup()

    def fake(self, name, code):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + code)
        path.chmod(0o700)

    def run_council(self, *extra, path=None, out_dir=True, text=True):
        env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + (path or os.environ["PATH"]),
            "CAPTURE": str(self.capture),
            "CLAUDECODE": "1",
            "HOME": str(self.root / "home"),
        }
        return subprocess.run(
            [
                sys.executable,
                str(COUNCIL),
                "--prompt-file",
                str(self.prompt),
                "--context-file",
                str(self.context),
                *(["--out-dir", str(self.root / "out")] if out_dir else []),
                *extra,
            ],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=text,
            timeout=60,
        )

    def captured(self, name):
        return json.loads((self.capture / f"{name}.json").read_text())

    def test_all_members_invoked_with_pinned_models_read_only(self):
        for name, code in FAKES.items():
            self.fake(name, code)
        result = self.run_council()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        codex = self.captured("codex")["argv"]
        self.assertEqual(codex[codex.index("--model") + 1], "gpt-6.2-sol")
        self.assertIn('model_reasoning_effort="medium"', codex)
        self.assertEqual(codex[codex.index("--sandbox") + 1], "read-only")

        claude = self.captured("claude")
        claude_argv = claude["argv"]
        self.assertEqual(claude_argv[claude_argv.index("--model") + 1], "claude-opus-5-5")
        self.assertEqual(claude_argv[claude_argv.index("--effort") + 1], "medium")
        self.assertEqual(claude_argv[claude_argv.index("--permission-mode") + 1], "plan")
        self.assertEqual(claude_argv[claude_argv.index("--tools") + 1], "Read,Grep,Glob")
        self.assertIsNone(claude["claudecode"])

        agy = self.captured("agy")["argv"]
        self.assertEqual(agy[agy.index("--model") + 1], "gemini-4-neon-high")
        self.assertEqual(agy[agy.index("--agent") + 1], "council-member-7c41e9")
        agent = (self.root / "home/.gemini/config/agents/council-member-7c41e9.md").read_text()
        self.assertIn("tools: [read_file]\n", agent)

        for name in ("codex", "claude"):
            stdin = self.captured(name)["stdin"]
            self.assertIn(self.prompt.read_text(), stdin)
            self.assertIn("+++ b", stdin)
        self.assertIn(self.prompt.read_text(), agy[-1])
        self.assertTrue(agy[-1].startswith("-p="))
        for argv in (codex, claude_argv, agy):
            self.assertFalse(any("fable" in a.lower() for a in argv))

        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())
        for finding in ("codex finding", "claude finding", "gemini finding"):
            self.assertIn(finding, result.stdout)
        self.assertNotIn("codex progress noise", result.stdout)
        council = (self.root / "out" / "council.md").read_text()
        self.assertIn("Gemini 4 Neon (high): ok", council)

    def test_one_failure_and_one_timeout_do_not_sink_the_rest(self):
        self.fake("codex", FAKES["codex"])
        self.fake("claude", RECORD + "sys.stderr.write('quota exhausted\\n'); sys.exit(5)\n")
        self.fake("agy", RECORD + "import time; time.sleep(30)\n")
        result = self.run_council("--timeout", "2")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("codex finding", result.stdout)
        self.assertIn("Claude Opus 5.5 (medium): failed: exit 5", result.stdout)
        self.assertIn("quota exhausted", result.stdout)
        self.assertIn("Gemini 4 Neon (high): failed: timed out after 2s", result.stdout)

    def test_gemini_timeout_keeps_the_partial_answer(self):
        self.fake("agy", agy_stream("half a finding", sleep=30))
        result = self.run_council("--members", "gemini", "--timeout", "2")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("Gemini 4 Neon (high): failed: timed out after 2s (partial answer kept)", result.stdout)
        self.assertIn("half a finding", (self.root / "out" / "gemini.md").read_text())
        self.assertIn("Partial answer", result.stdout)

    def test_gemini_print_timeout_reports_what_it_had_read(self):
        self.fake(
            "agy",
            RECORD
            + "tool = {'step_type': 'tool', 'state': 'DONE', 'tool_name': 'read_file', 'tool_info': {'parameters': {'Path': '/repo/a.nix'}}}\n"
            + "print(json.dumps({'event': 'step_update', 'step_update': tool}))\n"
            + "print(json.dumps({'event': 'result', 'result': {'status': 'ERROR', 'error': 'print timeout after 5s'}}))\n"
            + "sys.exit(3)\n",
        )
        result = self.run_council("--members", "gemini", "--timeout", "20")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("Gemini 4 Neon (high): failed: timed out after 20s (partial answer kept)", result.stdout)
        self.assertIn("It had read 1 path(s): `/repo/a.nix`", (self.root / "out" / "gemini.md").read_text())
        agy = self.captured("agy")["argv"]
        self.assertEqual(agy[agy.index("--print-timeout") + 1], "5s")

    def test_sign_in_text_elsewhere_is_not_a_sign_in_prompt(self):
        prompt = "Authentication required. Please visit the URL to log in:"
        self.fake(
            "codex",
            RECORD + f"import time\nprint({prompt!r}, flush=True)\ntime.sleep(1)\n" + FAKES["codex"][len(RECORD) :],
        )
        self.fake(
            "agy",
            RECORD
            + "import time\n"
            + "print(json.dumps({'event': 'init'}), flush=True)\n"
            + f"sys.stderr.write({prompt!r} + '\\n'); sys.stderr.flush(); time.sleep(1)\n"
            + "print(json.dumps({'event': 'result', 'result': {'status': 'SUCCESS', 'response': 'gemini finding'}}))\n",
        )
        result = self.run_council("--members", "codex,gemini")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("codex finding", result.stdout)
        self.assertIn("gemini finding", result.stdout)

    def test_a_users_agent_with_councils_name_is_not_overwritten(self):
        self.fake("agy", FAKES["agy"])
        agent = self.root / "home/.gemini/config/agents/council-member-7c41e9.md"
        agent.parent.mkdir(parents=True)
        agent.write_text("my own agent\n")
        result = self.run_council("--members", "gemini")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("wasn't written by council; move it aside", result.stdout)
        self.assertEqual(agent.read_text(), "my own agent\n")
        self.assertFalse((self.capture / "agy.json").exists())

    def test_an_older_council_agent_is_updated(self):
        self.fake("agy", FAKES["agy"])
        agent = self.root / "home/.gemini/config/agents/council-member-7c41e9.md"
        agent.parent.mkdir(parents=True)
        marker = "# Written by the council command, which rewrites this file; rename it to keep your own agent."
        agent.write_text(f"---\n{marker}\nname: old\n---\n")
        result = self.run_council("--members", "gemini")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("tools: [read_file]\n", agent.read_text())

    def test_an_empty_leftover_agent_is_replaced(self):
        self.fake("agy", FAKES["agy"])
        agent = self.root / "home/.gemini/config/agents/council-member-7c41e9.md"
        agent.parent.mkdir(parents=True)
        agent.write_text("")
        result = self.run_council("--members", "gemini")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("tools: [read_file]\n", agent.read_text())

    def test_concurrent_first_installs_both_succeed(self):
        home = self.root / "home"
        script = (
            "import sys, tempfile, threading, types\n"
            f"sys.path.insert(0, {str(COUNCIL.parent)!r})\n"
            "import council\n"
            "second_done = threading.Event()\n"
            "first = threading.Event()\n"
            "class Paused:\n"
            "    def __init__(self, f):\n"
            "        self.f, self.name = f, getattr(f, 'name', None)\n"
            "    def __enter__(self):\n"
            "        self.f.__enter__()\n"
            "        return self\n"
            "    def __exit__(self, *exc):\n"
            "        return self.f.__exit__(*exc)\n"
            "    def write(self, text):\n"
            "        if threading.current_thread().name == 'first':\n"
            "            first.set()\n"
            "            second_done.wait(timeout=10)\n"
            "        return self.f.write(text)\n"
            "council.open = lambda *a, **k: Paused(open(*a, **k))\n"
            "council.tempfile = types.SimpleNamespace(NamedTemporaryFile=lambda *a, **k: Paused(tempfile.NamedTemporaryFile(*a, **k)))\n"
            "errors = []\n"
            "def install():\n"
            "    try:\n"
            "        council.install_agy_agent()\n"
            "    except Exception as error:\n"
            "        errors.append(repr(error))\n"
            "a = threading.Thread(target=install, name='first')\n"
            "a.start()\n"
            "first.wait(timeout=10)\n"
            "install()\n"
            "second_done.set()\n"
            "a.join()\n"
            "print(errors)\n"
        )
        result = subprocess.run(
            [sys.executable, "-c", script],
            env=os.environ | {"HOME": str(home)},
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.stdout.strip(), "[]", result.stderr)
        agents = home / ".gemini/config/agents"
        self.assertEqual([p.name for p in agents.iterdir()], ["council-member-7c41e9.md"])
        self.assertIn("tools: [read_file]\n", (agents / "council-member-7c41e9.md").read_text())

    def test_gemini_without_login_fails_fast_without_the_sign_in_url(self):
        self.fake(
            "agy",
            RECORD
            + "import time\n"
            + "sys.stderr.write('Authentication required. Please visit the URL to log in:\\n  https://accounts.example/secret\\n')\n"
            + "sys.stderr.flush(); time.sleep(30)\n",
        )
        start = time.monotonic()
        result = self.run_council("--members", "gemini", "--timeout", "30")
        self.assertLess(time.monotonic() - start, 15)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("agy is not signed in; run `agy` on the host and sign in", result.stdout)
        self.assertNotIn("accounts.example", result.stdout)

    def test_missing_cli_is_reported(self):
        self.fake("codex", FAKES["codex"])
        result = self.run_council("--members", "codex,gemini", path="/nonexistent")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("failed: agy not found on PATH", result.stdout)
        self.assertNotIn("Claude", result.stdout)

    def test_large_prompt_is_passed_to_gemini_by_file(self):
        for name, code in FAKES.items():
            self.fake(name, code)
        self.context.write_text("x" * 150_000)
        result = self.run_council()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        agy = self.captured("agy")["argv"][-1]
        self.assertLess(len(agy), 1000)
        self.assertIn(str(self.root / "out" / "prompt.md"), agy)

    def test_stdout_is_bounded(self):
        self.fake("codex", RECORD + "argv = sys.argv[1:]\nPath(argv[argv.index('-o') + 1]).write_text('c' * 50_000)\n")
        self.fake("claude", RECORD + "print('d' * 50_000)\n")
        self.fake(
            "agy",
            RECORD
            + "print(json.dumps({'event': 'result', 'result': {'status': 'SUCCESS', 'response': 'g' * 50_000}}))\n",
        )
        result = self.run_council()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(len(result.stdout.encode()), 10_000)
        self.assertIn("[truncated; full text in", result.stdout)
        self.assertIn("c" * 50_000, (self.root / "out" / "council.md").read_text())

    def test_timeout_covers_a_member_that_never_reads_stdin(self):
        self.fake("codex", "import time; time.sleep(60)\n")
        self.fake("claude", "print('claude finding')\n")
        self.context.write_text("x" * 300_000)
        start = time.monotonic()
        result = self.run_council("--members", "codex,claude", "--timeout", "2")
        self.assertLess(time.monotonic() - start, 20)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("Codex gpt-6.2-sol (medium): failed: timed out after 2s", result.stdout)
        self.assertIn("Claude Opus 5.5 (medium): ok", result.stdout)
        self.assertIn("claude finding", result.stdout)

    def test_descendant_holding_stdout_neither_blocks_nor_loses_the_answer(self):
        self.fake(
            "claude",
            "import os, subprocess, sys\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            "open(os.path.join(os.environ['CAPTURE'], 'grandchild'), 'w').write(str(child.pid))\n"
            "print('claude finding', flush=True)\n",
        )
        start = time.monotonic()
        result = self.run_council("--members", "claude", "--timeout", "30")
        self.assertLess(time.monotonic() - start, 20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("claude finding", result.stdout)
        self.assertFalse(alive(int((self.capture / "grandchild").read_text())))

    def test_each_run_gets_a_fresh_directory(self):
        self.fake("codex", FAKES["codex"])
        first = self.run_council("--members", "codex", out_dir=False)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.fake("codex", "pass\n")
        second = self.run_council("--members", "codex", out_dir=False)
        self.assertEqual(second.returncode, 4, second.stdout + second.stderr)
        self.assertIn("failed: empty answer", second.stdout)
        self.assertEqual(len(list((self.root / ".tmp" / "council").iterdir())), 2)

        (self.root / "out").mkdir()
        (self.root / "out" / "codex.md").write_text("stale finding")
        reused = self.run_council("--members", "codex")
        self.assertEqual(reused.returncode, 2)
        self.assertIn("already exists", reused.stderr)

    def test_stdout_budget_counts_bytes_and_keeps_utf8_valid(self):
        self.fake("codex", RECORD + "argv = sys.argv[1:]\nPath(argv[argv.index('-o') + 1]).write_text('é' * 50_000)\n")
        self.fake("claude", RECORD + "print('🦀' * 50_000)\n")
        self.fake(
            "agy",
            RECORD
            + "print(json.dumps({'event': 'result', 'result': {'status': 'SUCCESS', 'response': 'λx' * 50_000}}))\n",
        )
        result = self.run_council(text=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLessEqual(len(result.stdout), 9_000)
        output = result.stdout.decode("utf-8")
        self.assertEqual(output.count("[truncated; full text in"), 3)

    def test_oversized_context_is_refused(self):
        self.context.write_text("x" * 500_000)
        result = self.run_council()
        self.assertEqual(result.returncode, 2)
        self.assertIn("pass less context", result.stderr)


if __name__ == "__main__":
    unittest.main()
