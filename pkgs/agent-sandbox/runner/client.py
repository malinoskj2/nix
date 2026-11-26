#!/usr/bin/env python3
import argparse
import json
import os
import socket
import subprocess
import sys
import time

SOCKET = os.environ.get("AGENT_SANDBOX_RUNNER_SOCKET", "/run/agent-sandbox-runner/runner.sock")


def fail(error):
    sys.exit(
        f"sandbox-runner: cannot reach the host runner at {SOCKET} ({error.strerror}); "
        "sandboxes started before it existed have none, so restart the session"
    )


def call(request, quiet=False):
    # The runner starts with the sandbox and sweeps leftovers before it listens.
    for attempt in range(50):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.connect(SOCKET)
            break
        except (FileNotFoundError, ConnectionRefusedError) as error:
            connection.close()
            if attempt == 49 or not os.path.isdir(os.path.dirname(SOCKET)):
                fail(error)
            time.sleep(0.2)
        except OSError as error:
            fail(error)

    with connection, connection.makefile("rwb") as stream:
        stream.write((json.dumps(request) + "\n").encode())
        stream.flush()
        for line in stream:
            message = json.loads(line)
            if "out" in message:
                if not quiet:
                    sys.stdout.write(message["out"])
                    sys.stdout.flush()
            elif "err" in message:
                sys.stderr.write(message["err"])
                sys.stderr.flush()
            elif "error" in message:
                sys.exit(f"sandbox-runner: {message['error']}")
            elif "result" in message:
                return message["result"]
    sys.exit("sandbox-runner: the runner closed the connection without a result")


def show(result):
    print(json.dumps(result, indent=2))


def finish(result):
    code = result.get("exit", 0)
    sys.exit(code if isinstance(code, int) and 0 <= code < 256 else 1)


def render(args, project):
    """Render the Compose file here, with what this sandbox can read, into the model the host checks."""
    command = ["docker-compose", "--project-name", project]
    for file in args.file or []:
        command += ["--file", file]
    if args.project_directory:
        command += ["--project-directory", args.project_directory]
    for profile in args.profile or []:
        command += ["--profile", profile]
    for env_file in args.env_file or []:
        command += ["--env-file", env_file]
    command += ["config", "--format", "json"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"sandbox-runner: docker compose config failed:\n{result.stderr}")
    model = json.loads(result.stdout)
    directory = args.project_directory or (os.path.dirname(os.path.abspath(args.file[0])) if args.file else os.getcwd())
    worktree = subprocess.run(
        ["git", "-C", directory, "rev-parse", "--show-toplevel"], capture_output=True, text=True
    ).stdout.strip()
    if not worktree:
        sys.exit(f"sandbox-runner: {directory} is not in a Git worktree")
    return model, os.path.realpath(worktree)


def default_name(args):
    directory = args.project_directory or (os.path.dirname(os.path.abspath(args.file[0])) if args.file else os.getcwd())
    name = "".join(c if c.isalnum() else "-" for c in os.path.basename(os.path.realpath(directory)).lower())
    return name.strip("-")[:24] or "stack"


def compose(args):
    name = args.name or default_name(args)
    base = {"name": name}
    if args.action in ("build", "up"):
        project = call({"op": "compose.project", **base})["project"]
        model, worktree = render(args, project)
        request = {
            **base,
            "op": f"compose.{args.action}",
            "model": model,
            "worktree": worktree,
            "services": args.services,
            "timeout": args.timeout,
        }
        if args.action == "up":
            request.update(build=args.build, wait=args.wait)
        result = call(request)
        if args.action == "up":
            show({"project": result["project"], "services": result["services"]})
        finish(result)
    if args.action == "ps":
        show(call({**base, "op": "compose.ps"}))
    elif args.action == "logs":
        finish(call({**base, "op": "compose.logs", "services": args.services, "tail": args.tail}))
    elif args.action == "exec":
        if len(args.command) < 2:
            sys.exit("usage: sandbox-runner compose exec SERVICE -- COMMAND...")
        finish(
            call(
                {
                    **base,
                    "op": "compose.exec",
                    "service": args.command[0],
                    "argv": strip_dashes(args.command[1:]),
                    "user": args.user,
                    "cwd": args.workdir,
                    "env": args.env,
                    "timeout": args.timeout,
                }
            )
        )
    elif args.action == "down":
        finish(call({**base, "op": "compose.down"}))


def strip_dashes(argv):
    return argv[1:] if argv and argv[0] == "--" else argv


def sandbox(args):
    if args.action == "launch":
        image = args.image
        if args.build:
            image = call({"op": "image.load", "path": args.build})["image"]
        worktree = os.path.realpath(
            args.worktree
            or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
            or os.getcwd()
        )
        show(
            call(
                {
                    "op": "sandbox.launch",
                    "image": image,
                    "worktree": worktree,
                    "display": args.display,
                    "gpu": not args.no_gpu,
                }
            )
        )
    elif args.action == "exec":
        argv = strip_dashes(args.command)
        if not argv:
            sys.exit("usage: sandbox-runner sandbox exec ID -- COMMAND...")
        finish(
            call(
                {
                    "op": "sandbox.exec",
                    "id": args.id,
                    "argv": argv,
                    "cwd": args.cwd,
                    "env": args.env,
                    "timeout": args.timeout,
                }
            )
        )
    elif args.action == "logs":
        finish(call({"op": "sandbox.logs", "id": args.id, "tail": args.tail}))
    elif args.action == "rm":
        show(call({"op": "sandbox.rm", "id": args.id}))


def main():
    parser = argparse.ArgumentParser(
        prog="sandbox-runner",
        description="Disposable sandboxes and Compose stacks on the host engine, owned by this sandbox.",
    )
    sub = parser.add_subparsers(dest="group", required=True)

    sub.add_parser("ls", help="list what this sandbox owns")

    image = sub.add_parser("image", help="load a candidate sandbox image").add_subparsers(dest="action", required=True)
    load = image.add_parser("load", help="load an image archive or stream script from /nix/store")
    load.add_argument("path")

    sb = sub.add_parser("sandbox", help="disposable sibling sandboxes").add_subparsers(dest="action", required=True)
    launch = sb.add_parser("launch", help="start a fresh sandbox sharing one worktree")
    source = launch.add_mutually_exclusive_group()
    source.add_argument(
        "--image", help="agent-sandbox:<tag> or a candidate from `image load`; default: this sandbox's image"
    )
    source.add_argument("--build", help="a store path from `nix build .#agent-sandbox.image`")
    launch.add_argument("--worktree", help="Git worktree to share read-write; default: the current one")
    launch.add_argument("--display", action="store_true", help="start the displays at launch")
    launch.add_argument("--no-gpu", action="store_true")
    for action in ("exec", "logs", "rm"):
        command = sb.add_parser(action)
        command.add_argument("id")
        if action == "exec":
            command.add_argument("--cwd")
            command.add_argument("--env", action="append", metavar="NAME=VALUE")
            command.add_argument("--timeout", type=int)
            command.add_argument("command", nargs=argparse.REMAINDER)
        if action == "logs":
            command.add_argument("--tail", type=int)

    cp = sub.add_parser("compose", help="Compose stacks on the host engine")
    cp.add_argument("-f", "--file", action="append")
    cp.add_argument("--project-directory")
    cp.add_argument("--profile", action="append")
    cp.add_argument("--env-file", action="append")
    cp.add_argument("--name", help="stack name; default: the project directory's name")
    actions = cp.add_subparsers(dest="action", required=True)
    for action in ("build", "up", "ps", "logs", "exec", "down"):
        command = actions.add_parser(action)
        if action in ("build", "up", "exec"):
            command.add_argument("--timeout", type=int)
        if action == "up":
            command.add_argument("--build", action="store_true")
            command.add_argument("--wait", action="store_true", help="wait until services are healthy")
        if action == "logs":
            command.add_argument("--tail", type=int)
        if action == "exec":
            command.add_argument("--user")
            command.add_argument("--workdir")
            command.add_argument("--env", action="append", metavar="NAME=VALUE")
            command.add_argument("command", nargs=argparse.REMAINDER)
        elif action in ("build", "up", "logs"):
            command.add_argument("services", nargs="*")

    args = parser.parse_args()
    if args.group == "ls":
        show(call({"op": "ls"}))
    elif args.group == "image":
        show(call({"op": "image.load", "path": args.path}))
    elif args.group == "sandbox":
        sandbox(args)
    else:
        if args.action in ("ps", "down", "exec"):
            args.services = []
        compose(args)


if __name__ == "__main__":
    main()
