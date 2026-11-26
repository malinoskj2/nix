"""Optional real CLI regression: no model is loaded; the API is a local test server."""

import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("qwen_local.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


@unittest.skipUnless(os.environ.get("QWEN_TEST_OPENCODE"), "Set QWEN_TEST_OPENCODE to a real OpenCode 2.x binary")
class RealOpenCodeTest(unittest.TestCase):
    def test_prompt_reaches_api_unchanged_via_stdin(self):
        version = subprocess.check_output([os.environ["QWEN_TEST_OPENCODE"], "--version"], text=True)
        self.assertEqual(runner.opencode_major(version), 2)
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for delta, finish in [({"role": "assistant", "content": "FORWARDING_OK"}, None), ({}, "stop")]:
                    chunk = {
                        "id": "test",
                        "object": "chat.completion.chunk",
                        "created": 1,
                        "model": "qwen",
                        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
                    }
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n")

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        prompt = '  Literal $(echo hello) `touch nothing` λ\n"second line"\n'
        try:
            with tempfile.TemporaryDirectory() as tmp:
                env = os.environ | {
                    "OPENCODE_CONFIG_CONTENT": json.dumps(runner.configuration(server.server_port, 2)),
                    "QWEN_LOCAL_API_KEY": "test",
                }
                result = subprocess.run(
                    [
                        os.environ["QWEN_TEST_OPENCODE"],
                        "run",
                        "--standalone",
                        "--model",
                        "local-qwen/qwen",
                        "--format",
                        "json",
                    ],
                    input=prompt,
                    env=env,
                    cwd=tmp,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("FORWARDING_OK", result.stdout)
                self.assertTrue(requests)
                self.assertTrue(requests[0].get("tools"), "Coding tools must reach the local model")
                messages = [m["content"] for m in requests[0]["messages"] if m["role"] == "user"]
                self.assertEqual(messages, [prompt])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
