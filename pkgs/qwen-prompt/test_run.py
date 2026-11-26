import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from qwen_local import STRATA_MODELS, healthy

RUNNER = Path(__file__).with_name("run.py")


class ForwardingTest(unittest.TestCase):
    def test_exact_prompt_and_cleanup_on_success_and_failure(self):
        for model_name, alias, filename, exit_code, strata in (
            ("regular", "qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf", 0, False),
            ("uncensored", "qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf", 7, False),
            ("regular", *STRATA_MODELS["regular"], 0, True),
            ("uncensored", *STRATA_MODELS["uncensored"], 3, True),
        ):
            with self.subTest(exit_code=exit_code, strata=strata), tempfile.TemporaryDirectory() as tmp:
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
                    "gpu-run": "pass",
                    "opencode": """import json, os, sys
from pathlib import Path
if '--version' in sys.argv:
    print('opencode v2.2.5')
else:
    Path(os.environ['CAPTURE']).write_text(json.dumps(sys.stdin.buffer.read().decode('utf-8')))
    print(json.dumps({'type': 'text', 'part': {'text': 'response'}}))
    sys.exit(int(os.environ['EXIT_CODE']))
""",
                    "llama-server": """import http.server, json, os, signal, sys
from pathlib import Path
Path(os.environ['SERVER_PID']).write_text(str(os.getpid()))
config = sys.argv[sys.argv.index('--config') + 1] if '--config' in sys.argv else None
Path(os.environ['SERVER_ARGV']).write_text(json.dumps([sys.argv[1:], config and json.loads(Path(config).read_text())]))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[sys.argv.index('--port') + 1])), Handler).serve_forever()
""",
                }
                scripts["strata-server"] = scripts["llama-server"]
                scripts["strata-tokenizer"] = """import sys
from pathlib import Path
out = Path(sys.argv[sys.argv.index('--out') + 1]) / 'tokenizer'
out.mkdir(parents=True)
(out / 'vocab.json').write_text('{}')
"""
                for name, code in scripts.items():
                    path = root / name
                    path.write_text(f"#!{sys.executable}\n" + code)
                    path.chmod(0o700)
                env = os.environ | {
                    "MODEL_ROOT": str(root),
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "GPU_LEASE_ID": "test-double",
                    "CAPTURE": str(root / "capture"),
                    "SERVER_PID": str(root / "pid"),
                    "SERVER_ARGV": str(root / "argv"),
                    "XDG_CACHE_HOME": str(root / "cache"),
                    "EXIT_CODE": str(exit_code),
                }
                result = subprocess.run(
                    [
                        sys.executable,
                        str(RUNNER),
                        "--model",
                        model_name,
                        "--prompt-file",
                        str(prompt_file),
                        *(["--strata"] if strata else []),
                        "--allocated",
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(json.loads((root / "capture").read_text()), prompt)
                argv, config = json.loads((root / "argv").read_text())
                if strata:
                    self.assertEqual(config["args"][config["args"].index("--native") + 1], str(model_dir / filename))
                    self.assertEqual(config["args"][config["args"].index("--max-context") + 1], "16384")
                else:
                    self.assertEqual(argv[argv.index("--ctx-size") + 1], "16384")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)


class BookingTest(unittest.TestCase):
    def test_dense_books_26gib_and_strata_the_whole_gpu(self):
        for strata, booking in ((False, ["--vram", "26GiB"]), (True, ["--exclusive"])):
            with self.subTest(strata=strata), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                alias, filename = STRATA_MODELS["regular"] if strata else ("qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf")
                (root / "by-name" / alias).mkdir(parents=True)
                (root / "by-name" / alias / filename).write_bytes(b"fake")
                (root / "catalog.json").write_text(
                    json.dumps({"entries": {alias: {"files": [{"target": filename, "size": 4}]}}})
                )
                (root / "readiness.json").write_text(json.dumps({"entries": {alias: {"status": "ready"}}}))
                (root / "prompt.txt").write_text("hello")
                scripts = {
                    "gpu-run": "import json, os, sys\nopen(os.environ['CAPTURE'], 'w').write(json.dumps(sys.argv[1:]))",
                    "opencode": "",
                    "llama-server": "",
                    "strata-server": "",
                    "strata-tokenizer": """import sys
from pathlib import Path
out = Path(sys.argv[sys.argv.index('--out') + 1]) / 'tokenizer'
out.mkdir(parents=True)
(out / 'vocab.json').write_text('{}')
""",
                }
                for name, code in scripts.items():
                    (root / name).write_text(f"#!{sys.executable}\n" + code)
                    (root / name).chmod(0o700)
                env = {key: value for key, value in os.environ.items() if key != "GPU_LEASE_ID"} | {
                    "MODEL_ROOT": str(root),
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "CAPTURE": str(root / "capture"),
                    "XDG_CACHE_HOME": str(root / "cache"),
                }
                command = [sys.executable, str(RUNNER), "--model", "regular", "--prompt-file", str(root / "prompt.txt")]
                result = subprocess.run(
                    command + (["--strata"] if strata else []), env=env, capture_output=True, text=True, timeout=15
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                argv = json.loads((root / "capture").read_text())
                self.assertEqual(argv[: len(booking)], booking)
                self.assertEqual("--strata" in argv, strata)
                self.assertEqual((root / "cache" / "qwen-prompt" / "strata" / filename).is_dir(), strata)


class HealthTest(unittest.TestCase):
    def test_strata_loading_is_not_healthy(self):
        for body, expected in ((b'{"status": "ok", "loaded": false}', False), (b'{"loaded": true}', True), (b"", True)):
            with self.subTest(body=body):

                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self, body=body):
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

                    def log_message(self, *args):
                        pass

                server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
                threading.Thread(target=server.handle_request, daemon=True).start()
                try:
                    self.assertIs(healthy(server.server_port, "key"), expected)
                finally:
                    server.server_close()


if __name__ == "__main__":
    unittest.main()
