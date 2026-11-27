import http.server
import json
import os
import secrets
import socket
import string
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "ghs_" + secrets.token_hex(18)


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    calls = []

    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.calls.append(("POST", self.path, body, self.headers["Authorization"].split(" ")[0]))
        self.reply(201, {"token": TOKEN})

    def do_GET(self):
        self.calls.append(("GET", self.path, None, self.headers["Authorization"]))
        self.reply(200, {"default_branch": "trunk"})

    def do_DELETE(self):
        self.calls.append(("DELETE", self.path, None, self.headers["Authorization"]))
        self.send_response(204)
        self.end_headers()


def run(*args, cwd, check=True):
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    env.update(
        GIT_AUTHOR_NAME="t",
        GIT_AUTHOR_EMAIL="t@example.invalid",
        GIT_COMMITTER_NAME="t",
        GIT_COMMITTER_EMAIL="t@example.invalid",
    )
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=check)


class PushGateway(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.d = cls.tmp.name
        api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=api.serve_forever, daemon=True).start()
        cls.api = api
        subprocess.run(["openssl", "genrsa", "-out", f"{d}/app.pem", "2048"], check=True, capture_output=True)
        os.makedirs(f"{d}/github/owner")
        cls.remote = f"{d}/github/owner/repo.git"
        run("git", "init", "--bare", "--quiet", "--initial-branch=trunk", cls.remote, cwd=d)
        cls.work = f"{d}/work"
        run("git", "init", "--quiet", "--initial-branch=trunk", cls.work, cwd=d)
        cls.commit("README", "hello\n")
        run("git", "push", "--quiet", cls.remote, "trunk", cwd=cls.work)
        run("git", "remote", "add", "origin", "https://github.com/owner/repo.git", cwd=cls.work)
        cls.config = f"{d}/push.json"
        cls.configure(appId=None)
        cls.socket = f"{d}/push.sock"
        cls.log = open(f"{d}/push.log", "w+")
        cls.server = subprocess.Popen(
            [sys.executable, "-I", f"{HERE}/push.py", "--socket", cls.socket, "--config", cls.config],
            stdout=cls.log,
            stderr=subprocess.STDOUT,
        )
        for _ in range(100):
            if os.path.exists(cls.socket):
                break
            time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)
        cls.api.shutdown()
        cls.log.close()
        cls.tmp.cleanup()

    @classmethod
    def configure(cls, **override):
        config = {
            "appId": 1,
            "installationId": 2,
            "keyFile": f"{cls.d}/app.pem",
            "repos": ["owner/repo", "malinoskj2/nix"],
            "protectedBranches": ["main", "master"],
            "api": f"http://127.0.0.1:{cls.api.server_address[1]}",
            "gitBase": f"file://{cls.d}/github",
        }
        config.update(override)
        with open(cls.config, "w") as f:
            json.dump(config, f)

    @classmethod
    def commit(cls, name, content):
        with open(f"{cls.work}/{name}", "w") as f:
            f.write(content)
        run("git", "add", name, cwd=cls.work)
        run("git", "commit", "--quiet", "-m", f"change {name}", cwd=cls.work)
        return run("git", "rev-parse", "HEAD", cwd=cls.work).stdout.strip()

    def push(self, *args):
        return run(sys.executable, "-I", f"{HERE}/sandbox-push.py", *args, cwd=self.work, check=False)

    def remote_head(self, branch):
        result = run("git", "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}", cwd=self.remote, check=False)
        return result.stdout.strip() or None

    def setUp(self):
        os.environ["AGENT_PUSH_SOCKET"] = self.socket
        FakeGitHub.calls.clear()
        self.configure()
        run("git", "checkout", "--quiet", "trunk", cwd=self.work)

    def branch(self, name):
        run("git", "checkout", "--quiet", "-B", name, "trunk", cwd=self.work)

    def test_1_unconfigured_fails_closed_with_instructions(self):
        self.configure(appId=None)
        self.branch("feature-a")
        result = self.push()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("isn't set up yet", result.stderr)
        self.configure(keyFile=f"{self.d}/absent.pem")
        self.assertIn("secret add", self.push().stderr)

    def test_2_pushes_a_new_branch_with_a_scoped_token(self):
        self.branch("feature-b")
        tip = self.commit("b.txt", "b\n")
        result = self.push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head("feature-b"), tip)
        mint = [c for c in FakeGitHub.calls if c[0] == "POST"]
        self.assertEqual(mint[0][2], {"repositories": ["repo"], "permissions": {"contents": "write"}})
        self.assertEqual(mint[0][3], "Bearer")
        self.assertEqual(len([c for c in FakeGitHub.calls if c[0] == "DELETE"]), len(mint), "every token is revoked")
        self.log.flush()
        with open(self.log.name) as f:
            self.assertNotIn(TOKEN, f.read())

    def test_3_refuses_protected_and_default_branches(self):
        for name in ("main", "trunk"):
            self.branch(name)
            self.commit(f"{name}.txt", "x\n")
            result = self.push()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("feature branch", result.stderr)
        run("git", "checkout", "--quiet", "trunk", cwd=self.work)
        run("git", "reset", "--quiet", "--hard", "HEAD~1", cwd=self.work)
        self.assertIn("feature branch", self.push("main", "--repo", "malinoskj2/nix").stderr)

    def test_4_refuses_unlisted_repos(self):
        self.branch("feature-c")
        self.commit("c.txt", "c\n")
        self.assertIn("agentBroker.push.repos", self.push("--repo", "owner/other").stderr)

    def test_5_refuses_a_force_push(self):
        self.branch("feature-d")
        self.commit("d.txt", "d\n")
        self.assertEqual(self.push().returncode, 0)
        run("git", "reset", "--quiet", "--hard", "trunk", cwd=self.work)
        self.commit("d2.txt", "other\n")
        result = self.push()
        self.assertIn("never force-pushes", result.stderr)

    def test_6_refuses_commits_with_secrets(self):
        self.branch("feature-e")
        fake = "ghp_" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        self.commit("config.env", f"GITHUB_TOKEN={fake}\n")
        result = self.push()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Betterleaks", result.stderr)
        self.assertNotIn(fake, result.stderr)
        self.assertIsNone(self.remote_head("feature-e"))

    def test_7_updates_a_branch_fast_forward(self):
        self.branch("feature-f")
        self.commit("f.txt", "f\n")
        self.assertEqual(self.push().returncode, 0)
        tip = self.commit("f2.txt", "f2\n")
        result = self.push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head("feature-f"), tip)

    def test_8_missing_gateway_is_explained(self):
        os.environ["AGENT_PUSH_SOCKET"] = f"{self.d}/absent.sock"
        self.assertIn("no push gateway", self.push().stderr)


class Sockets(unittest.TestCase):
    def test_oversized_header_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            path = f"{d}/push.sock"
            with open(f"{d}/push.json", "w") as f:
                json.dump({}, f)
            server = subprocess.Popen(
                [sys.executable, "-I", f"{HERE}/push.py", "--socket", path, "--config", f"{d}/push.json"],
                stdout=subprocess.DEVNULL,
            )
            try:
                for _ in range(100):
                    if os.path.exists(path):
                        break
                    time.sleep(0.05)
                with socket.socket(socket.AF_UNIX) as s:
                    s.connect(path)
                    s.sendall(b"x" * 70000 + b"\n")
                    reply = json.loads(s.makefile().readline())
                self.assertFalse(reply["ok"])
            finally:
                server.terminate()
                server.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
