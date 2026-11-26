import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

LAUNCHER = Path(__file__).with_name("opencode.py")

GPU_RUN = """import os, signal, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[args.index('--vram') + 1] == '26GiB', args
assert '--exclusive' not in args
command = args[args.index('--') + 1:]
log = Path(os.environ['GPU_LOG'])
def interrupted(signum, _frame):
    with log.open('a') as f:
        f.write(f'cancel {os.getpid()}\\n')
    sys.exit(143)
signal.signal(signal.SIGTERM, interrupted)
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
assert argv[argv.index('--ctx-size') + 1] == '65536'
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
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
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

OPENCODE = """import json, os, sys, time, urllib.error, urllib.request
from pathlib import Path
if '--version' in sys.argv:
    print('opencode v2.3.0')
    sys.exit()
assert sys.argv[1:] == ['--standalone', 'project-dir', '--prompt', '-h', '--uncensored'], sys.argv
config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
assert config['model'] == 'local-qwen/qwen'
assert config['providers']['local-qwen']['models']['qwen']['limit']['context'] == 65536
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

def chat(text, stream=True):
    return call('/chat/completions', {'model': 'qwen', 'stream': stream, 'messages': [{'role': 'user', 'content': text}]})

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
assert json.loads(call('/models'))['data'][0]['id'] == 'qwen'
assert 'acquire' not in events(), 'listing models must not load Qwen'
if scenario == 'cycle':
    body = chat('hello idle world')
    assert ': waiting for a GPU reservation' in body, body
    assert 'HELLO' in body and 'WORLD' in body and '[DONE]' in body, body
    wait_for(lambda: events().count('release') == 1)
    assert json.loads(chat('again', stream=False))['choices'][0]['message']['content'] == 'AGAIN'
    assert events().count('acquire') == 2
    sys.exit(int(os.environ['EXIT_CODE']))
chat('hold the model')
Path(os.environ['READY']).write_text('')
time.sleep(60)
"""


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        alias, filename = "qwen3.8-27b-uncensored", "Qwen3.8-27B-Uncensored-Q5_K_M.gguf"
        (self.root / "by-name" / alias).mkdir(parents=True)
        (self.root / "by-name" / alias / filename).write_bytes(b"fake")
        (self.root / "catalog.json").write_text(
            json.dumps({"entries": {alias: {"files": [{"target": filename, "size": 4}]}}})
        )
        (self.root / "readiness.json").write_text(json.dumps({"entries": {alias: {"status": "ready"}}}))
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, code in {"gpu-run": GPU_RUN, "llama-server": LLAMA_SERVER, "opencode": OPENCODE}.items():
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
        }

    def tearDown(self):
        self.tmp.cleanup()

    def launch(self, scenario, **env):
        return subprocess.Popen(
            [
                sys.executable,
                str(LAUNCHER),
                "--uncensored",
                "--idle-minutes",
                "0.02",
                "project-dir",
                "--prompt",
                "-h",
                "--uncensored",
            ],
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
        while not (self.root / "state" / "qwen-opencode").exists() or not any(
            "requesting" in log.read_text() for log in (self.root / "state" / "qwen-opencode").iterdir()
        ):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)
        process.terminate()
        process.communicate(timeout=30)
        self.assertEqual((self.root / "gpu.log").read_text().split()[0], "cancel")

    def test_unready_model_starts_nothing(self):
        (self.root / "readiness.json").write_text(
            json.dumps({"entries": {"qwen3.8-27b-uncensored": {"status": "missing"}}})
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


if __name__ == "__main__":
    unittest.main()
