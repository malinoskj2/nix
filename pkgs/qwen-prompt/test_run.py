import concurrent.futures
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock
from pathlib import Path

from qwen_local import MOE_MODELS, healthy, strata_command, strata_tokenizer

RUNNER = Path(__file__).with_name("run.py")


class ForwardingTest(unittest.TestCase):
    def test_exact_prompt_and_cleanup_on_success_and_failure(self):
        for model_name, alias, filename, exit_code, mode in (
            ("regular", "qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf", 0, "dense"),
            ("uncensored", "qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf", 7, "dense"),
            ("regular", *MOE_MODELS["regular"], 0, "moe"),
            ("uncensored", *MOE_MODELS["uncensored"], 5, "moe"),
            ("regular", *MOE_MODELS["regular"], 0, "strata"),
            ("uncensored", *MOE_MODELS["uncensored"], 3, "strata"),
        ):
            with self.subTest(exit_code=exit_code, mode=mode), tempfile.TemporaryDirectory() as tmp:
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
for name in ('vocab.json', 'merges.txt', 'tokenizer.json', 'token_type.json'):
    (out / name).write_text('{}')
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
                        *([] if mode == "dense" else [f"--{mode}"]),
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
                if mode == "strata":
                    self.assertEqual(config["args"][config["args"].index("--native") + 1], str(model_dir / filename))
                    self.assertEqual(config["args"][config["args"].index("--max-context") + 1], "16384")
                else:
                    self.assertEqual(argv[argv.index("--ctx-size") + 1], "16384")
                    self.assertEqual(argv[argv.index("--model") + 1], str(model_dir / filename))
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)


class BookingTest(unittest.TestCase):
    def test_dense_and_moe_book_26gib_and_strata_the_whole_gpu(self):
        for mode, booking in (
            ("dense", ["--vram", "26GiB"]),
            ("moe", ["--vram", "26GiB"]),
            ("strata", ["--exclusive"]),
        ):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                alias, filename = (
                    MOE_MODELS["regular"] if mode != "dense" else ("qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf")
                )
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
for name in ('vocab.json', 'merges.txt', 'tokenizer.json', 'token_type.json'):
    (out / name).write_text('{}')
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
                    command + ([] if mode == "dense" else [f"--{mode}"]),
                    check=False,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                argv = json.loads((root / "capture").read_text())
                self.assertEqual(argv[: len(booking)], booking)
                self.assertEqual(
                    [flag for flag in ("--moe", "--strata") if flag in argv], [] if mode == "dense" else [f"--{mode}"]
                )
                self.assertEqual((root / "cache" / "qwen-prompt" / "strata" / filename).is_dir(), mode == "strata")


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


class TokenizerCacheTest(unittest.TestCase):
    EXTRACTOR = """import os, sys
from pathlib import Path
out = Path(sys.argv[sys.argv.index('--out') + 1]) / 'tokenizer'
out.mkdir(parents=True)
with open(os.environ['TOKENIZER_LOG'], 'a') as log:
    log.write(os.environ['TOKENIZER_MODE'] + '\\n')
(out / 'vocab.json').write_text('{"a": 0')
if os.environ['TOKENIZER_MODE'] == 'crash':
    sys.exit(1)
(out / 'vocab.json').write_text('{"a": 0}')
if os.environ['TOKENIZER_MODE'] == 'good':
    for name in ('merges.txt', 'tokenizer.json', 'token_type.json'):
        (out / name).write_text('{}')
"""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.root)])
        bin = self.root / "bin"
        bin.mkdir()
        (bin / "strata-tokenizer").write_text(f"#!{sys.executable}\n" + self.EXTRACTOR)
        (bin / "strata-tokenizer").chmod(0o700)
        self.model = self.root / "model.gguf"
        self.model.write_text("")
        self.cache = self.root / "cache" / "qwen-prompt" / "strata"
        self.log = self.root / "tokenizer.log"
        env = {
            "PATH": f"{bin}:{os.environ['PATH']}",
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "TOKENIZER_LOG": str(self.log),
        }
        patcher = unittest.mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def extract(self, mode):
        with unittest.mock.patch.dict(os.environ, {"TOKENIZER_MODE": mode}):
            return strata_tokenizer(self.model)

    def test_failed_extraction_publishes_nothing_and_the_next_run_rebuilds(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.extract("crash")
        self.assertEqual(list(self.cache.iterdir()), [])
        tokenizer = self.extract("good")
        self.assertEqual(tokenizer, self.cache / "model.gguf" / "tokenizer")
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), ["model.gguf"])
        self.extract("good")
        self.assertEqual(self.log.read_text().split(), ["crash", "good"])

    def test_incomplete_extraction_that_exits_zero_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete tokenizer"):
            self.extract("partial")
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_an_incomplete_existing_cache_is_rebuilt(self):
        partial = self.cache / "model.gguf" / "tokenizer"
        partial.mkdir(parents=True)
        (partial / "vocab.json").write_text('{"a": 0}')
        tokenizer = self.extract("good")
        self.assertTrue((tokenizer / "token_type.json").is_file())
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), ["model.gguf"])
        self.assertEqual(self.log.read_text().split(), ["good"])

    def test_concurrent_extractions_all_return_a_complete_cache(self):
        with (
            unittest.mock.patch.dict(os.environ, {"TOKENIZER_MODE": "good"}),
            concurrent.futures.ThreadPoolExecutor(4) as pool,
        ):
            results = list(pool.map(lambda _: strata_tokenizer(self.model), range(4)))
        for tokenizer in results:
            self.assertTrue((tokenizer / "tokenizer.json").is_file())
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), ["model.gguf"])

    def test_the_server_runs_offline(self):
        self.extract("good")
        command = strata_command(self.model, 1, "key", 4096, self.root)
        self.assertIn("--offline", command)


if __name__ == "__main__":
    unittest.main()
