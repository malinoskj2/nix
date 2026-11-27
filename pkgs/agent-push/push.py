import argparse
import base64
import json
import os
import re
import socketserver
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
BRANCH = re.compile(r"^(?!.*\.\.)(?!.*//)(?!/)(?!.*/$)(?!.*\.lock$)[A-Za-z0-9._/-]{1,200}$")
SHA = re.compile(r"^[0-9a-f]{40}$")
MAX_HEADER = 65536
MAX_BUNDLE = 512 * 1024 * 1024
ALWAYS_PROTECTED = {("malinoskj2/nix", "main")}


class Refused(Exception):
    pass


def log(**record):
    record = {"ts": round(time.time(), 3), **record}
    sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class GitHub:
    def __init__(self, config):
        self.config = config
        self.api = config.get("api", "https://api.github.com")

    def configured(self):
        if not self.config.get("appId") or not self.config.get("installationId"):
            raise Refused(
                "the push gateway isn't set up yet: the owner has to create the GitHub App and set "
                "agentBroker.push.appId and installationId (see docs/agent-egress.md)"
            )
        key = self.config.get("keyFile")
        if not key or not os.path.exists(key):
            raise Refused(
                "the push gateway has no GitHub App key yet: the owner has to add github-app-key with `secret add`"
            )

    def jwt(self):
        now = int(time.time())
        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
        claims = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(self.config["appId"])}).encode())
        signing_input = f"{header}.{claims}".encode()
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.config["keyFile"]],
            input=signing_input,
            capture_output=True,
        )
        if result.returncode != 0:
            raise Refused("could not sign with the GitHub App key")
        return f"{header}.{claims}.{b64url(result.stdout)}"

    def request(self, method, path, token, body=None, auth="Bearer"):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.api}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"{auth} {token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "agent-push",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            raise Refused(f"GitHub answered {error.code} for {method} {path.split('?')[0]}") from None
        except OSError as error:
            raise Refused(f"GitHub is unreachable: {error}") from None
        return json.loads(payload) if payload else {}

    def token(self, repo):
        self.configured()
        name = repo.split("/", 1)[1]
        reply = self.request(
            "POST",
            f"/app/installations/{self.config['installationId']}/access_tokens",
            self.jwt(),
            {"repositories": [name], "permissions": {"contents": "write"}},
        )
        if not reply.get("token"):
            raise Refused("GitHub gave no installation token")
        return reply["token"]

    def default_branch(self, repo, token):
        return self.request("GET", f"/repos/{repo}", token, auth="token").get("default_branch") or "main"

    def revoke(self, token):
        try:
            self.request("DELETE", "/installation/token", token, auth="token")
        except Refused:
            pass


class Push:
    def __init__(self, config, github):
        self.config = config
        self.github = github
        self.git_base = config.get("gitBase", "https://github.com")

    def check(self, repo, branch):
        if not isinstance(repo, str) or not REPO.match(repo):
            raise Refused("repo must be owner/name")
        if not isinstance(branch, str) or not BRANCH.match(branch) or branch.startswith("refs/"):
            raise Refused("branch must be a plain branch name")
        allowed = self.config.get("repos", [])
        if repo.lower() not in {r.lower() for r in allowed}:
            raise Refused(f"{repo} isn't in agentBroker.push.repos")
        if (repo.lower(), branch) in ALWAYS_PROTECTED or branch in self.config.get("protectedBranches", []):
            raise Refused(f"pushing to {branch} of {repo} is refused; push a feature branch and open a pull request")

    def git(self, directory, *args, env=None, check=True, input=None):
        base = {
            "PATH": os.environ["PATH"],
            "HOME": directory,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "LANG": "C.UTF-8",
        }
        result = subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=user", *args],
            cwd=directory,
            env={**base, **(env or {})},
            capture_output=True,
            text=True,
            input=input,
            timeout=900,
        )
        if check and result.returncode != 0:
            raise Refused(f"git {args[0]} failed: {result.stderr.strip()[-400:]}")
        return result

    def askpass(self, directory, token):
        script = os.path.join(directory, "askpass")
        with open(script, "w") as f:
            f.write(
                '#!/bin/sh\ncase "$1" in Username*) echo x-access-token ;; *) printf %s "$AGENT_PUSH_TOKEN" ;; esac\n'
            )
        os.chmod(script, 0o700)
        return {"GIT_ASKPASS": script, "AGENT_PUSH_TOKEN": token}

    def remote_heads(self, directory, url, auth, branches):
        result = self.git(directory, "ls-remote", "--heads", url, *[f"refs/heads/{b}" for b in branches], env=auth)
        heads = {}
        for line in result.stdout.splitlines():
            sha, _, ref = line.partition("\t")
            if SHA.match(sha):
                heads[ref.removeprefix("refs/heads/")] = sha
        return heads

    def prepare(self, request):
        repo, branch = request.get("repo"), request.get("branch")
        self.check(repo, branch)
        token = self.github.token(repo)
        try:
            default = self.github.default_branch(repo, token)
            if branch == default:
                raise Refused(f"{branch} is {repo}'s default branch; push a feature branch and open a pull request")
            with tempfile.TemporaryDirectory(prefix="agent-push-") as directory:
                heads = self.remote_heads(directory, self.url(repo), self.askpass(directory, token), [branch, default])
        finally:
            self.github.revoke(token)
        return {"ok": True, "default": default, "heads": heads}

    def url(self, repo):
        return f"{self.git_base}/{repo}.git"

    def push(self, request, bundle_path):
        repo, branch, tip = request.get("repo"), request.get("branch"), request.get("tip")
        self.check(repo, branch)
        if not isinstance(tip, str) or not SHA.match(tip):
            raise Refused("tip must be a full commit id")
        token = self.github.token(repo)
        try:
            default = self.github.default_branch(repo, token)
            if branch == default:
                raise Refused(f"{branch} is {repo}'s default branch; push a feature branch and open a pull request")
            with tempfile.TemporaryDirectory(prefix="agent-push-") as directory:
                return self.push_in(directory, repo, branch, tip, default, token, bundle_path)
        finally:
            self.github.revoke(token)

    def push_in(self, directory, repo, branch, tip, default, token, bundle_path):
        auth = self.askpass(directory, token)
        url = self.url(repo)
        git_dir = os.path.join(directory, "repo.git")
        os.mkdir(git_dir)
        self.git(git_dir, "init", "--bare", "--quiet")
        self.git(git_dir, "remote", "add", "origin", url)
        heads = self.remote_heads(git_dir, url, auth, [branch, default])
        refspecs = [f"+refs/heads/{b}:refs/remotes/origin/{b}" for b in heads]
        if refspecs:
            self.git(git_dir, "fetch", "--quiet", "--filter=blob:none", "origin", *refspecs, env=auth)
        self.git(git_dir, "bundle", "verify", "--quiet", bundle_path)
        self.git(git_dir, "fetch", "--quiet", bundle_path, f"+refs/heads/{branch}:refs/push/tip")
        fetched = self.git(git_dir, "rev-parse", "refs/push/tip").stdout.strip()
        if fetched != tip:
            raise Refused("the bundle's branch doesn't point at the claimed tip")
        current = heads.get(branch)
        if current:
            if current == tip:
                return {"ok": True, "message": f"{branch} is already at {tip[:12]}"}
            if self.git(git_dir, "merge-base", "--is-ancestor", current, tip, check=False).returncode != 0:
                raise Refused(f"{branch} on GitHub isn't an ancestor of {tip[:12]}; the gateway never force-pushes")
            scan = f"{current}..{tip}"
        else:
            scan = f"{tip} --not --remotes=origin" if heads else tip
        self.scan(git_dir, scan, auth)
        self.git(git_dir, "push", "--quiet", "origin", f"{tip}:refs/heads/{branch}", env=auth)
        log(event="push", repo=repo, branch=branch, tip=tip, scanned=scan)
        return {"ok": True, "message": f"pushed {tip[:12]} to {repo} {branch}"}

    def scan(self, git_dir, log_opts, auth):
        result = subprocess.run(
            [
                "betterleaks",
                "git",
                "--no-banner",
                "--redact",
                "--verbose",
                "--log-level",
                "warn",
                f"--log-opts={log_opts}",
                ".",
            ],
            cwd=git_dir,
            env={
                "PATH": os.environ["PATH"],
                "HOME": git_dir,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                **auth,
            },
            capture_output=True,
            text=True,
            timeout=900,
        )
        if result.returncode != 0:
            findings = (result.stdout + result.stderr).strip()[-4000:]
            log(event="scan-refused", scanned=log_opts)
            raise Refused(
                f"Betterleaks found possible secrets; remove them from these commits and push again:\n{findings}"
            )


def read_exact(stream, size, target):
    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, 1 << 20))
        if not chunk:
            raise Refused("the bundle ended early")
        target.write(chunk)
        remaining -= len(chunk)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = {}
        try:
            line = self.rfile.readline(MAX_HEADER + 1)
            if len(line) > MAX_HEADER:
                raise Refused("request too long")
            request = json.loads(line or b"{}")
            reply = self.server.dispatch(request, self.rfile)
        except Refused as error:
            reply = {"ok": False, "error": str(error)}
        except (ValueError, KeyError, TypeError) as error:
            reply = {"ok": False, "error": f"bad request: {error}"}
        except subprocess.TimeoutExpired:
            reply = {"ok": False, "error": "timed out"}
        if not reply.get("ok"):
            op = request.get("op") if isinstance(request, dict) else None
            log(
                event="refused",
                op=str(op)[:16],
                repo=str(request.get("repo"))[:200] if isinstance(request, dict) else None,
                error=reply["error"][:300],
            )
        self.wfile.write((json.dumps(reply) + "\n").encode())


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path, config_path):
        self.config_path = config_path
        super().__init__(path, Handler)

    def dispatch(self, request, stream):
        with open(self.config_path) as f:
            config = json.load(f)
        push = Push(config, GitHub(config))
        op = request.get("op")
        if op == "prepare":
            return push.prepare(request)
        if op == "push":
            size = request.get("size")
            if not isinstance(size, int) or not 0 < size <= MAX_BUNDLE:
                raise Refused(f"the bundle must be between 1 byte and {MAX_BUNDLE >> 20} MiB")
            with tempfile.NamedTemporaryFile(prefix="agent-push-", suffix=".bundle") as bundle:
                read_exact(stream, size, bundle)
                bundle.flush()
                return push.push(request, bundle.name)
        raise Refused(f"unknown op {op!r}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Push sandbox branches to GitHub with a GitHub App token")
    parser.add_argument("--socket", default=os.path.join(os.environ.get("AGENT_BROKER_SOCKET_DIR", "."), "push.sock"))
    parser.add_argument("--config", default="/etc/agent-broker/push.json")
    args = parser.parse_args(argv)
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    server = Server(args.socket, args.config)
    os.chmod(args.socket, 0o660)
    log(event="start")
    server.serve_forever()


if __name__ == "__main__":
    main()
