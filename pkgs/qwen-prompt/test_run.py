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

import qwen_local
from qwen_local import MOE_MODELS, healthy, resolve_model, strata_command, strata_pack

RUNNER = Path(__file__).with_name("run.py")
PACKER = """import os, sys
from pathlib import Path
assert '--experts-bin' in sys.argv, sys.argv
out = Path(sys.argv[sys.argv.index('--out') + 1])
(out / 'tokenizer').mkdir(parents=True)
mode = os.environ.get('PACK_MODE', 'good')
if 'PACK_LOG' in os.environ:
    with open(os.environ['PACK_LOG'], 'a') as log:
        log.write(mode + '\\n')
(out / 'tokenizer' / 'vocab.json').write_text('{"a": 0')
if mode == 'crash':
    sys.exit(1)
(out / 'tokenizer' / 'vocab.json').write_text('{"a": 0}')
(out / 'tokenizer' / 'tokenizer.json').write_text('{}')
(out / 'experts.bin').write_bytes(b'experts')
if mode == 'good':
    (out / 'native_experts.txt').write_text('0 IQ3_XXS Q2_0 0 1 0 0 0\\n')
"""


class ForwardingTest(unittest.TestCase):
    def test_exact_prompt_and_cleanup_on_success_and_failure(self):
        for model_name, alias, filename, exit_code, mode in (
            ("regular", "qwen3.8-27b", "Qwen3.8-27B-Q5_K_M.gguf", 0, "dense"),
            ("uncensored", "qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf", 7, "dense"),
            ("regular", *MOE_MODELS["regular"], 0, "moe"),
            ("uncensored", *MOE_MODELS["uncensored"], 5, "moe"),
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
                scripts["strata-pack"] = PACKER
                scripts["strata"] = ""
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
                if mode == "moe":
                    args = config["args"]
                    self.assertEqual(args[args.index("--native") + 1], str(model_dir / filename))
                    self.assertEqual(
                        args[args.index("--ple-gguf") + 1],
                        str(model_dir / filename.replace("-00001-of-", "-00002-of-")),
                    )
                    self.assertEqual(args[args.index("--mtp") + 1], str(model_dir / "mtp" / "rt"))
                    self.assertEqual(
                        args[args.index("--pack") + 1], str(root / "cache" / "qwen-prompt" / "strata" / filename)
                    )
                    self.assertEqual(args[args.index("--max-context") + 1], "16384")
                    self.assertEqual(args[args.index("--kv") + 1], "int8")
                    self.assertIn("--resident-experts", args)
                    self.assertEqual(args[args.index("--expert-cache") + 1], "5200")
                    self.assertEqual(args[args.index("--resident-budget-gib") + 1], "32")
                    self.assertEqual(args[args.index("--conversation-cache-mib") + 1], "4096")
                    self.assertEqual(args[args.index("--ple-io") + 1], "direct")
                    self.assertEqual(config["arch"], "qwen4exp")
                else:
                    self.assertEqual(argv[argv.index("--ctx-size") + 1], "16384")
                    self.assertEqual(argv[argv.index("--model") + 1], str(model_dir / filename))
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)


class BookingTest(unittest.TestCase):
    def test_dense_books_26gib_and_moe_its_default_profile(self):
        for mode, booking in (
            ("dense", ["--vram", "26GiB"]),
            ("moe", ["--vram", "23GiB"]),
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
                    "strata-pack": PACKER,
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
                self.assertEqual("--moe" in argv, mode == "moe")
                self.assertEqual((root / "cache" / "qwen-prompt" / "strata" / filename).is_dir(), mode == "moe")


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


class ReadinessTest(unittest.TestCase):
    def test_every_file_of_the_entry_must_be_complete(self):
        alias, filename = MOE_MODELS["regular"]
        second = filename.replace("-00001-of-", "-00002-of-")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            model_dir = root / "by-name" / alias
            model_dir.mkdir(parents=True)
            (model_dir / filename).write_bytes(b"fake")
            (model_dir / second).write_bytes(b"fa")
            files = [{"target": filename, "size": 4}, {"target": second, "size": 4}]
            (root / "catalog.json").write_text(json.dumps({"entries": {alias: {"files": files}}}))
            (root / "readiness.json").write_text(json.dumps({"entries": {alias: {"status": "ready"}}}))
            with unittest.mock.patch.dict(os.environ, {"MODEL_ROOT": str(root)}):
                with self.assertRaisesRegex(RuntimeError, second):
                    resolve_model("regular", "moe")
                (model_dir / second).write_bytes(b"fake")
                self.assertEqual(resolve_model("regular", "moe"), model_dir / filename)


class PackCacheTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.root)])
        bin = self.root / "bin"
        bin.mkdir()
        (bin / "strata-pack").write_text(f"#!{sys.executable}\n" + PACKER)
        (bin / "strata-pack").chmod(0o700)
        (bin / "strata").write_text("")
        (bin / "strata").chmod(0o700)
        self.models = self.root / "models"
        self.model = self.models / "by-name" / "flash" / "model-00001-of-00002.gguf"
        self.model.parent.mkdir(parents=True)
        self.model.write_text("")
        self.catalog("a" * 64)
        self.cache = self.root / "cache" / "qwen-prompt" / "strata"
        self.log = self.root / "pack.log"
        env = {
            "PATH": f"{bin}:{os.environ['PATH']}",
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "PACK_LOG": str(self.log),
            "MODEL_ROOT": str(self.models),
        }
        patcher = unittest.mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def catalog(self, digest):
        files = [
            {"target": self.model.name, "size": 0, "sha256": digest},
            {"target": "model-00002-of-00002.gguf", "size": 0, "sha256": "b" * 64},
            {"target": "mtp/rt/experts.bin", "size": 0, "sha256": "c" * 64},
        ]
        (self.models / "catalog.json").write_text(json.dumps({"entries": {"flash": {"files": files}}}))

    def entries(self):
        return sorted(p.name for p in self.cache.iterdir() if p.suffix != ".lock")

    def build(self, mode):
        with unittest.mock.patch.dict(os.environ, {"PACK_MODE": mode}):
            return strata_pack(self.model)

    def test_failed_build_publishes_nothing_and_the_next_run_rebuilds(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.build("crash")
        self.assertEqual(self.entries(), [])
        self.assertEqual([p for p in self.cache.iterdir() if p.name.startswith(".")], [])
        pack = self.build("good")
        self.assertEqual(pack, self.cache / self.model.name)
        self.assertEqual(self.entries(), [self.model.name])
        self.build("good")
        self.assertEqual(self.log.read_text().split(), ["crash", "good"])

    def test_incomplete_build_that_exits_zero_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            self.build("partial")
        self.assertEqual(self.entries(), [])
        self.assertEqual([p for p in self.cache.iterdir() if p.name.startswith(".")], [])

    def test_an_incomplete_existing_pack_is_rebuilt(self):
        partial = self.cache / self.model.name / "tokenizer"
        partial.mkdir(parents=True)
        (partial / "vocab.json").write_text('{"a": 0}')
        pack = self.build("good")
        self.assertTrue((pack / "native_experts.txt").is_file())
        self.assertEqual(self.entries(), [self.model.name])
        self.assertEqual(self.log.read_text().split(), ["good"])

    def test_concurrent_builds_all_return_a_complete_pack(self):
        with (
            unittest.mock.patch.dict(os.environ, {"PACK_MODE": "good"}),
            concurrent.futures.ThreadPoolExecutor(4) as pool,
        ):
            results = list(pool.map(lambda _: strata_pack(self.model), range(4)))
        for pack in results:
            self.assertTrue(qwen_local.pack_complete(pack, qwen_local.pack_source(self.model)))
        self.assertEqual(self.entries(), [self.model.name])

    def test_concurrent_builds_run_once(self):
        with (
            unittest.mock.patch.dict(os.environ, {"PACK_MODE": "good"}),
            concurrent.futures.ThreadPoolExecutor(4) as pool,
        ):
            list(pool.map(lambda _: strata_pack(self.model), range(4)))
        self.assertEqual(self.log.read_text().split(), ["good"])

    def test_a_new_model_file_under_the_same_name_rebuilds_the_pack(self):
        self.build("good")
        self.model.write_text("replaced")
        self.catalog("d" * 64)
        pack = self.build("good")
        self.assertEqual(self.log.read_text().split(), ["good", "good"])
        self.assertEqual(json.loads((pack / "source.json").read_text())["shards"][self.model.name], "d" * 64)
        self.assertEqual(self.entries(), [self.model.name])

    def test_another_strata_build_rebuilds_the_pack(self):
        self.build("good")
        other = self.root / "other" / "bin"
        other.mkdir(parents=True)
        (other / "strata").write_text("")
        (other / "strata").chmod(0o700)
        with unittest.mock.patch.dict(os.environ, {"PATH": f"{other}:{os.environ['PATH']}"}):
            self.build("good")
        self.assertEqual(self.log.read_text().split(), ["good", "good"])

    def test_a_killed_build_leaves_no_staging_behind_the_next_one(self):
        leftover = self.cache / f".{self.model.name}.killed" / "pack"
        leftover.mkdir(parents=True)
        (leftover / "experts.bin").write_bytes(b"partial")
        self.build("good")
        self.assertEqual(self.entries(), [self.model.name])
        self.assertEqual([p for p in self.cache.iterdir() if p.name.startswith(".")], [])

    def test_the_server_runs_offline(self):
        self.build("good")
        command = strata_command(self.model, 1, "key", 4096, self.root)
        self.assertIn("--offline", command)


if __name__ == "__main__":
    unittest.main()
