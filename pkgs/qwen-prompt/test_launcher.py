import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from qwen_local import MODELS, MOE_MODELS

LAUNCHER = Path(__file__).with_name("opencode.py")

GPU_RUN = """import os, signal, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
if os.environ['EXPECT_VRAM'] == 'exclusive':
    assert '--exclusive' in args and '--vram' not in args, args
elif os.environ['EXPECT_VRAM'] != 'any':
    assert args[args.index('--vram') + 1] == os.environ['EXPECT_VRAM'], args
    assert '--exclusive' not in args
with Path(os.environ['BOOKINGS']).open('a') as f:
    f.write(args[args.index('--vram') + 1] + '\\n')
command = args[args.index('--') + 1:]
log = Path(os.environ['GPU_LOG'])
def interrupted(signum, _frame):
    with log.open('a') as f:
        f.write(f'cancel {os.getpid()}\\n')
    sys.exit(143)
signal.signal(signal.SIGTERM, interrupted)
with log.open('a') as f:
    f.write(f'queued {os.getpid()}\\n')
time.sleep(float(os.environ.get('GPU_QUEUE', '0')))
with log.open('a') as f:
    f.write(f'acquire {os.getpid()}\\n')
child = subprocess.Popen(command, env=os.environ | {'GPU_LEASE_ID': 'fake'}, start_new_session=True)
def forward(signum, _frame):
    try:
        os.killpg(child.pid, signum)
    except ProcessLookupError:
        pass
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, forward)
code = child.wait()
with log.open('a') as f:
    f.write(f'release {os.getpid()}\\n')
sys.exit(code)
"""

LLAMA_SERVER = """import http.server, json, os, sys
from pathlib import Path
assert os.environ.get('GPU_LEASE_ID') == 'fake'
argv = sys.argv
if 'strata' in argv[0]:
    config = json.loads(Path(argv[argv.index('--config') + 1]).read_text())
    args = config['args']
    assert argv[argv.index('--engine') + 1] == 'strata' and '--offline' in argv, argv
    assert args[args.index('--native') + 1].endswith(os.environ['EXPECT_MODEL']), args
    assert os.environ['EXPECT_CONTEXT'] in ('any', args[args.index('--max-context') + 1]), args
    with Path(os.environ['CONTEXTS']).open('a') as f:
        f.write(args[args.index('--max-context') + 1] + ' ' + args[args.index('--expert-cache') + 1] + '\\n')
    assert args[args.index('--kv') + 1] == 'int8' and config['arch'] == 'qwen4exp', config
    assert '--resident-experts' in args and '--ple-gguf' in args, args
    assert Path(config['exe']).is_absolute(), config
    assert Path(config['tokenizer'], 'vocab.json').is_file(), config
else:
    assert argv[argv.index('--ctx-size') + 1] == os.environ['EXPECT_CONTEXT']
    assert argv[argv.index('--model') + 1].endswith(os.environ['EXPECT_MODEL']), argv
key = argv[argv.index('--api-key') + 1]
with Path(os.environ['SERVER_PIDS']).open('a') as f:
    f.write(f'{os.getpid()}\\n')
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def authorized(self):
        if self.headers.get('Authorization') == f'Bearer {key}':
            return True
        self.send_response(401)
        self.send_header('Content-Length', '0')
        self.end_headers()
        return False
    def do_GET(self):
        if self.authorized():
            body = json.dumps({'status': 'ok', 'loaded': True}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def do_POST(self):
        if not self.authorized():
            return
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = request['messages'][-1]['content'].upper()
        self.send_response(200)
        if request.get('stream'):
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            for word in text.split():
                chunk = {'choices': [{'delta': {'content': word}}]}
                self.wfile.write(('data: ' + json.dumps(chunk) + '\\n\\n').encode())
                self.wfile.flush()
            self.wfile.write(b'data: [DONE]\\n\\n')
        else:
            body = json.dumps({'choices': [{'message': {'content': text}}]}).encode()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', int(argv[argv.index('--port') + 1])), Handler).serve_forever()
"""

STRATA_PACK = """import os, sys
from pathlib import Path
argv = sys.argv
assert argv[argv.index('--gguf') + 1].endswith('-00001-of-00002.gguf') and '--experts-bin' in argv, argv
with Path(os.environ['PACK_LOG']).open('a') as f:
    f.write('built\\n')
out = Path(argv[argv.index('--out') + 1])
(out / 'tokenizer').mkdir(parents=True)
for name in ('vocab.json', 'tokenizer.json'):
    (out / 'tokenizer' / name).write_text('{}')
(out / 'experts.bin').write_bytes(b'experts')
(out / 'native_experts.txt').write_text('0\\n')
"""

OPENCODE = """import json, os, socket, struct, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path
if '--version' in sys.argv:
    print('opencode v2.3.0')
    sys.exit()
assert sys.argv[1:] == ['--standalone', 'project-dir', '--prompt', '-h', '--uncensored', '--moe'], sys.argv
config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
default = os.environ['EXPECT_DEFAULT']
models = config['providers']['local-qwen']['models']
assert config['model'] == f'local-qwen/{default}' and config['small_model'] == 'local-qwen/qwen', config
if os.environ['EXPECT_CONTEXT'] != 'any':
    assert models[default]['limit']['context'] == int(os.environ['EXPECT_CONTEXT']), models
base = config['providers']['local-qwen']['settings']['baseURL']
key = os.environ['QWEN_LOCAL_API_KEY']
log = Path(os.environ['GPU_LOG'])

def events():
    return log.read_text().split() if log.exists() else []

def call(path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(base + path, data=data, headers={'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode()

def chat(text, stream=True, model=default):
    return call('/chat/completions', {'model': model, 'stream': stream, 'messages': [{'role': 'user', 'content': text}]})

def wait_for(predicate):
    deadline = time.monotonic() + 15
    while not predicate():
        assert time.monotonic() < deadline, events()
        time.sleep(0.1)

try:
    urllib.request.urlopen(base + '/models', timeout=5)
    raise AssertionError('unauthenticated request accepted')
except urllib.error.HTTPError as error:
    assert error.code == 401

scenario = os.environ['SCENARIO']
assert sorted(m['id'] for m in json.loads(call('/models'))['data']) == sorted(models), call('/models')
assert 'acquire' not in events(), 'listing models must not load Qwen'
if scenario == 'cycle':
    body = chat('hello idle world')
    assert ': waiting for a GPU reservation' in body, body
    assert 'HELLO' in body and 'WORLD' in body and '[DONE]' in body, body
    wait_for(lambda: events().count('release') == 1)
    assert json.loads(chat('again', stream=False))['choices'][0]['message']['content'] == 'AGAIN'
    assert events().count('acquire') == 2
    sys.exit(int(os.environ['EXIT_CODE']))
if scenario == 'reset':
    url = urllib.parse.urlsplit(base)
    for _ in range(3):
        client = socket.create_connection((url.hostname, url.port), timeout=5)
        client.sendall(f'GET /v1/models HTTP/1.1\\r\\nHost: x\\r\\nAuthorization: Bearer {key}\\r\\n\\r\\n'.encode())
        assert client.recv(65536).startswith(b'HTTP/1.1 200'), 'keep-alive listing failed'
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        client.close()
    time.sleep(0.5)
    assert 'HELLO' in chat('hello', stream=False)
    sys.exit(0)
if scenario == 'switch':
    assert 'HELLO' in chat('hello', model='flash-next-12g')
    assert 'TITLE' in chat('title', model='qwen')
    assert 'BACK' in chat('back', stream=False)
    assert 'SMALL' in chat('small', model='qwen')
    assert events().count('acquire') == 2 and events().count('release') == 1, events()
    sys.exit(0)
chat('hold the model')
Path(os.environ['READY']).write_text('')
time.sleep(60)
"""


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        models = [MODELS["uncensored"], MOE_MODELS["uncensored"]]
        for alias, filename in models:
            (self.root / "by-name" / alias).mkdir(parents=True)
            (self.root / "by-name" / alias / filename).write_bytes(b"fake")
        catalog = {alias: {"files": [{"target": filename, "size": 4}]} for alias, filename in models}
        (self.root / "catalog.json").write_text(json.dumps({"entries": catalog}))
        (self.root / "readiness.json").write_text(
            json.dumps({"entries": {alias: {"status": "ready"} for alias, _ in models}})
        )
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        scripts = {
            "gpu-run": GPU_RUN,
            "llama-server": LLAMA_SERVER,
            "strata-server": LLAMA_SERVER,
            "strata-pack": STRATA_PACK,
            "strata": "",
            "opencode": OPENCODE,
        }
        for name, code in scripts.items():
            path = bin_dir / name
            path.write_text(f"#!{sys.executable}\n" + code)
            path.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items() if key != "GPU_LEASE_ID"} | {
            "MODEL_ROOT": str(self.root),
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "XDG_STATE_HOME": str(self.root / "state"),
            "GPU_LOG": str(self.root / "gpu.log"),
            "SERVER_PIDS": str(self.root / "servers"),
            "READY": str(self.root / "ready"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "PACK_LOG": str(self.root / "pack.log"),
            "EXPECT_VRAM": "26GiB",
            "EXPECT_CONTEXT": "65536",
            "EXPECT_MODEL": MODELS["uncensored"][1],
            "EXPECT_DEFAULT": "qwen",
            "BOOKINGS": str(self.root / "bookings"),
            "CONTEXTS": str(self.root / "contexts"),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def launch(self, scenario, mode="dense", **env):
        own = ["--uncensored", "--idle-minutes", "0.02", *(f"--{flag}" for flag in mode.split() if flag != "dense")]
        return subprocess.Popen(
            [sys.executable, str(LAUNCHER), *own, "project-dir", "--prompt", "-h", "--uncensored", "--moe"],
            env=self.env | {"SCENARIO": scenario} | env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def assert_released(self):
        deadline = time.monotonic() + 15
        servers = [int(pid) for pid in (self.root / "servers").read_text().split()]
        while True:
            events = (self.root / "gpu.log").read_text().split()
            alive = []
            for pid in servers:
                try:
                    os.kill(pid, 0)
                    alive.append(pid)
                except ProcessLookupError:
                    pass
            if not alive and events.count("acquire") == events.count("release"):
                return events
            self.assertLess(time.monotonic(), deadline, (events, alive))
            time.sleep(0.1)

    def wait_ready(self, process):
        deadline = time.monotonic() + 15
        while not (self.root / "ready").exists():
            self.assertIsNone(process.poll(), process.stderr.read() if process.poll() is not None else "")
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)

    def test_idle_unload_reacquire_and_exit_status(self):
        process = self.launch("cycle", EXIT_CODE="7", GPU_QUEUE="0.5")
        _, stderr = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 7, stderr)
        events = self.assert_released()
        self.assertEqual(events.count("acquire"), 2)
        self.assertEqual(len((self.root / "servers").read_text().split()), 2)

    def test_moe_serves_flash_next_in_its_default_profile_and_caches_its_pack(self):
        self.env |= {
            "EXPECT_VRAM": "23GiB",
            "EXPECT_CONTEXT": "262144",
            "EXPECT_MODEL": MOE_MODELS["uncensored"][1],
            "EXPECT_DEFAULT": "flash-next-20g",
        }
        for _ in range(2):
            for name in ("gpu.log", "servers"):
                (self.root / name).unlink(missing_ok=True)
            process = self.launch("cycle", "moe", EXIT_CODE="0", GPU_QUEUE="0.5")
            _, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn(MOE_MODELS["uncensored"][0], stderr)
            self.assertEqual(self.assert_released().count("acquire"), 2)
        self.assertEqual((self.root / "pack.log").read_text().split(), ["built"])
        self.assertEqual((self.root / "contexts").read_text().split()[:2], ["262144", "5200"])

    def test_picking_another_profile_reloads_strata_under_its_booking(self):
        self.env |= {
            "EXPECT_VRAM": "any",
            "EXPECT_CONTEXT": "any",
            "EXPECT_MODEL": MOE_MODELS["uncensored"][1],
            "EXPECT_DEFAULT": "flash-next-20g",
        }
        process = self.launch("switch", "moe")
        _, stderr = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 0, stderr)
        self.assert_released()
        self.assertEqual((self.root / "bookings").read_text().split(), ["13GiB", "23GiB"])
        self.assertEqual((self.root / "contexts").read_text().split(), ["131072", "1650", "262144", "5200"])
        self.assertNotIn("errors were logged", stderr)

    def test_a_client_resetting_its_connection_prints_nothing(self):
        process = self.launch("reset")
        _, stderr = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(len(stderr.splitlines()), 1, stderr)
        self.assertIn("loads on demand", stderr)
        log = (self.root / "state" / "qwen-prompt" / "qwen-opencode-uncensored.log").read_text()
        self.assertIn("GET /v1/models", log)
        self.assertNotIn("Traceback", log)

    def test_one_flash_next_runs_at_a_time(self):
        lock = self.root / "cache" / "qwen-prompt" / "strata" / "serve.lock"
        lock.parent.mkdir(parents=True)
        with open(lock, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            waiter = subprocess.Popen(
                [sys.executable, str(LAUNCHER.with_name("qwen_local.py")), "--strata-lock", "true"],
                env=self.env,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(1)
            self.assertIsNone(waiter.poll())
        _, stderr = waiter.communicate(timeout=15)
        self.assertEqual(waiter.returncode, 0, stderr)
        self.assertIn("Waiting for another Flash-Next to unload", stderr)

    def test_strata_flag_is_refused(self):
        process = self.launch("cycle", "strata")
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 2)
        self.assertIn("--moe", stderr)
        self.assertFalse((self.root / "gpu.log").exists())

    def test_moe_model_not_ready_starts_nothing(self):
        (self.root / "readiness.json").write_text(
            json.dumps({"entries": {MOE_MODELS["uncensored"][0]: {"status": "missing"}}})
        )
        process = self.launch("cycle", "moe")
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 1)
        self.assertIn("not ready; no download or fallback attempted", stderr)
        self.assertFalse((self.root / "gpu.log").exists())
        self.assertFalse((self.root / "pack.log").exists())

    def test_termination_stops_server_and_opencode(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                for name in ("gpu.log", "servers", "ready"):
                    (self.root / name).unlink(missing_ok=True)
                process = self.launch("hold")
                self.wait_ready(process)
                process.send_signal(sig)
                process.communicate(timeout=60)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(self.assert_released().count("acquire"), 1)

    def test_crash_of_launcher_still_releases(self):
        process = self.launch("hold")
        self.wait_ready(process)
        process.kill()
        process.communicate(timeout=30)
        self.assertEqual(self.assert_released().count("acquire"), 1)

    def test_queued_request_cancelled_on_exit(self):
        process = self.launch("hold", GPU_QUEUE="60")
        deadline = time.monotonic() + 15
        log = self.root / "gpu.log"
        while not log.exists() or "queued" not in log.read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)
        process.terminate()
        process.communicate(timeout=30)
        self.assertEqual(log.read_text().split()[::2], ["queued", "cancel"])

    def test_unready_model_starts_nothing(self):
        (self.root / "readiness.json").write_text(
            json.dumps({"entries": {MODELS["uncensored"][0]: {"status": "missing"}}})
        )
        process = self.launch("cycle")
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 1)
        self.assertIn("not ready; no download or fallback attempted", stderr)
        self.assertFalse((self.root / "gpu.log").exists())

    def test_refuses_to_nest_in_a_reservation(self):
        self.env["GPU_LEASE_ID"] = "outer"
        process = self.launch("cycle")
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 1)
        self.assertIn("Already inside a GPU reservation", stderr)


class LogTest(unittest.TestCase):
    def test_a_handler_failure_is_logged_not_printed_and_the_log_rotates(self):
        from opencode import Log, Proxy

        with tempfile.TemporaryDirectory() as directory:
            log = Log(Path(directory) / "proxy.log", limit=256)
            proxy = Proxy(("127.0.0.1", 0), None, log)
            try:
                try:
                    raise ConnectionResetError(104, "Connection reset by peer")
                except ConnectionResetError:
                    proxy.handle_error(None, ("127.0.0.1", 1))
                self.assertFalse(log.failed)
                try:
                    raise ValueError("boom")
                except ValueError:
                    proxy.handle_error(None, ("127.0.0.1", 1))
            finally:
                proxy.server_close()
            self.assertTrue(log.failed)
            self.assertIn("ValueError: boom", Path(log.name).read_text())
            for _ in range(20):
                log.line("x" * 64)
            log.close()
            self.assertLess(Path(log.name).stat().st_size, 512)
            self.assertTrue(Path(log.name + ".1").exists())


class BoundedLogTest(unittest.TestCase):
    def test_a_line_longer_than_the_limit_is_split_across_the_backup(self):
        from opencode import Log

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.log"
            log = Log(path, limit=256)
            log.write("x" * 4096 + "\n")
            log.close()
            self.assertEqual(path.stat().st_size, 1)
            self.assertEqual(Path(f"{path}.1").stat().st_size, 256)

    def test_child_output_without_newlines_is_copied_in_bounded_chunks(self):
        import opencode

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "progress.log"
            log = opencode.Log(path, limit=1024)
            reader, writer = os.pipe()
            sizes = []
            original = log.write_bytes
            log.write_bytes = lambda data: (sizes.append(len(data)), original(data))
            log.follow(os.fdopen(reader, "rb"))
            progress = "".join(f"\rloading λ {n}%" for n in range(100)).encode() * 100
            os.write(writer, progress)
            os.close(writer)
            for thread in log.readers:
                thread.join(5)
            log.close()
            self.assertTrue(sizes and max(sizes) <= opencode.READ_CHUNK, sizes[:5])
            self.assertTrue(progress.endswith(path.read_bytes()))


class QueueTest(unittest.TestCase):
    def test_the_small_model_follows_a_pending_switch(self):
        from opencode import Backend

        with tempfile.TemporaryDirectory() as directory, open(Path(directory) / "log", "w") as log:
            backend = Backend(Path(directory) / "model", "test", 60, log, directory, "moe")
            backend.profile, backend.ready = "flash-next-12g", True
            selected, ready, _ = backend.acquire("flash-next-20g", 0)
            self.assertFalse(ready)
            title, ready, _ = backend.acquire("qwen", 0)
            self.assertFalse(ready, "a title must not jump ahead of the pending switch")
            self.assertEqual([backend.wants(0), backend.wants(1)], ["flash-next-20g", "flash-next-20g"])
            backend.profile = "flash-next-20g"
            self.assertEqual(backend.wait(selected, 0), (True, None))
            self.assertEqual(backend.wait(title, 0), (True, None))
            self.assertEqual(backend.waiting, [])
            later, ready, _ = backend.acquire("qwen", 0)
            self.assertTrue(ready)
            for ticket in (selected, title, later):
                backend.release(ticket)
            self.assertEqual(backend.serving, 0)


if __name__ == "__main__":
    unittest.main()
