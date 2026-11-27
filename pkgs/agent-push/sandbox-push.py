import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

SOCKET = os.environ.get("AGENT_PUSH_SOCKET", "/run/agent-push/push.sock")
GITHUB = re.compile(r"^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?/?$")


def die(message):
    print(f"sandbox-push: {message}", file=sys.stderr)
    sys.exit(1)


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        die(f"git {args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def has_commit(sha):
    return subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode == 0


def call(request, bundle=None):
    if not os.path.exists(SOCKET):
        die(f"no push gateway at {SOCKET}; this sandbox started without agentBroker.push")
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(SOCKET)
        s.sendall((json.dumps(request) + "\n").encode())
        if bundle:
            with open(bundle, "rb") as f:
                while chunk := f.read(1 << 20):
                    s.sendall(chunk)
        reply = json.loads(s.makefile().readline() or "{}")
    if not reply.get("ok"):
        die(reply.get("error", "the gateway closed the connection"))
    return reply


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="sandbox-push", description="Push the current branch to GitHub through the host's push gateway"
    )
    parser.add_argument("branch", nargs="?", help="local branch to push (default: the current one)")
    parser.add_argument("--remote", default="origin", help="remote whose GitHub repository to push to")
    parser.add_argument("--repo", help="owner/name, instead of reading it from the remote")
    args = parser.parse_args(argv)
    branch = args.branch or git("symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if not branch:
        die("HEAD is detached; name a branch")
    repo = args.repo
    if not repo:
        url = git("remote", "get-url", args.remote)
        match = GITHUB.match(url)
        if not match:
            die(f"{args.remote} ({url}) isn't a GitHub repository; pass --repo owner/name")
        repo = match.group(1)
    tip = git("rev-parse", "--verify", f"refs/heads/{branch}^{{commit}}")
    heads = call({"op": "prepare", "repo": repo, "branch": branch})["heads"]
    if heads.get(branch) == tip:
        print(f"sandbox-push: {branch} is already at {tip[:12]} on {repo}")
        return
    haves = [sha for sha in heads.values() if has_commit(sha)]
    with tempfile.TemporaryDirectory() as directory:
        bundle = os.path.join(directory, "push.bundle")
        excludes = [f"^{sha}" for sha in haves]
        git("bundle", "create", "--quiet", bundle, f"refs/heads/{branch}", *excludes)
        reply = call(
            {"op": "push", "repo": repo, "branch": branch, "tip": tip, "size": os.path.getsize(bundle)}, bundle
        )
    print(f"sandbox-push: {reply['message']}")


if __name__ == "__main__":
    main()
