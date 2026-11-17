import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name("run.py")


class ForwardingTest(unittest.TestCase):
    def test_exact_prompt_and_cleanup_on_success_and_failure(self):
        for model_name, alias, filename, exit_code in (
            ("regular", "qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf", 0),
            ("uncensored", "qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf", 7),
        ):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                model_dir = root / "by-name" / alias
                model_dir.mkdir(parents=True)
                (model_dir / filename).write_bytes(b"fake")
                (root / "catalog.json").write_text(
                    json.dumps({"entries": {alias: {"files": [{"target": filename, "size": 4}]}}})
                )
                (root / "readiness.json").write_text(json.dumps({"entries": {alias: {"status": "ready"}}}))
                prompt = '  --literal $(touch SHOULD_NOT_EXIST) `echo test`\nQuotes: "hello" λ\n\n'
                prompt_file = root / "prompt.txt"
                prompt_file.write_text(prompt)
                scripts = {
                    "resource-run": "pass",
                    "opencode": """import json, os, sys
from pathlib import Path
if '--version' in sys.argv:
    print('opencode v2.2.5')
else:
    Path(os.environ['CAPTURE']).write_text(json.dumps(sys.stdin.buffer.read().decode('utf-8')))
    print(json.dumps({'type': 'text', 'part': {'text': 'response'}}))
    sys.exit(int(os.environ['EXIT_CODE']))
""",
                    "llama-server": """import http.server, os, signal, sys
from pathlib import Path
Path(os.environ['SERVER_PID']).write_text(str(os.getpid()))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[sys.argv.index('--port') + 1])), Handler).serve_forever()
""",
                }
                for name, code in scripts.items():
                    path = root / name
                    path.write_text(f"#!{sys.executable}\n" + code)
                    path.chmod(0o700)
                env = os.environ | {
                    "MODEL_ROOT": str(root),
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "RESOURCE_JOB_ID": "test-double",
                    "CAPTURE": str(root / "capture"),
                    "SERVER_PID": str(root / "pid"),
                    "EXIT_CODE": str(exit_code),
                }
                result = subprocess.run(
                    [
                        sys.executable,
                        str(RUNNER),
                        "--model",
                        model_name,
                        "--project",
                        "test",
                        "--prompt-file",
                        str(prompt_file),
                        "--allocated",
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(json.loads((root / "capture").read_text()), prompt)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)


if __name__ == "__main__":
    unittest.main()
