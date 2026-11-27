"""Interactive OpenCode on local Qwen, loading the model on demand and unloading it when idle."""

import argparse
import fcntl
import http.client
import http.server
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from dataclasses import dataclass
from pathlib import Path

from qwen_local import (
    MOE_DEFAULT,
    MOE_PROFILES,
    checked_opencode_major,
    configuration,
    guarded,
    healthy,
    mode_of,
    model_alias,
    moe_booking,
    opencode_environment,
    refuse_nesting,
    require,
    resolve_model,
    server_binary,
    server_command,
    stop,
    strata_pack,
)

CONTEXT = 65536
# Hybrid Qwen3.8 27B: 16 of 65 layers use attention, 4 KV heads of 256, so an
# f16 KV cache costs 64 KiB per token, 4 GiB at 64k. Regular weights are
# 19.5 GiB; measured peak with a full context is in docs/gpu-scheduler.md.
BOOKING = ("--vram", "26GiB")
# "qwen" is OpenCode's small model. On --moe it takes whichever profile is
# loaded, so titles and summaries never reload Strata, and the smallest
# context, since it can land on any of them.
ANY_PROFILE = "qwen"
KEEPALIVE = 15
LOG_LIMIT = 8 * 1024 * 1024
READ_CHUNK = 65536
LOGS_KEPT = 10
# How long shutdown waits for children's output; a leftover descendant can hold a pipe open.
DRAIN_TIMEOUT = 5
# OpenCode closing an idle keep-alive connection, or going away mid-stream.
DISCONNECTS = (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError)


@dataclass(frozen=True)
class Profile:
    title: str
    context: int
    booking: tuple
    moe: object = None


def profiles(mode):
    """The models the proxy serves, by OpenCode model ID, and the default one."""
    if mode == "dense":
        return {ANY_PROFILE: Profile("Local Qwen", CONTEXT, BOOKING)}, ANY_PROFILE
    return {
        name: Profile(profile.title, profile.context, moe_booking(profile), profile)
        for name, profile in MOE_PROFILES.items()
    }, MOE_DEFAULT


def listed_models(served):
    models = {name: (profile.title, profile.context) for name, profile in served.items()}
    if ANY_PROFILE not in served:
        models[ANY_PROFILE] = ("Flash-Next, loaded profile", min(profile.context for profile in served.values()))
    return models


class Log:
    """The session's log file, which takes everything the proxy and servers would print instead of OpenCode's TTY.

    Each session has its own, which moves to a single .1 backup once it
    reaches LOG_LIMIT, so it never holds more than twice that.
    """

    def __init__(self, path, limit=LOG_LIMIT, session_lock=None):
        self.name = str(path)
        self.session_lock = session_lock
        self.limit = limit
        self.lock = threading.Lock()
        self.failed = False
        self.readers = []
        self.closed = False
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.file = open(path, "ab", buffering=0)
        self.size = self.file.seek(0, os.SEEK_END)

    def write(self, text):
        self.write_bytes(text.encode("utf-8", "replace"))

    def write_bytes(self, data):
        """Append data, splitting it at the size limit so neither file grows past it."""
        with self.lock:
            while data and not self.closed:
                if self.size >= self.limit:
                    self.file.close()
                    os.replace(self.name, self.name + ".1")
                    self.file = open(self.name, "ab", buffering=0)
                    self.size = 0
                piece = data[: self.limit - self.size]
                self.file.write(piece)
                self.size += len(piece)
                data = data[len(piece) :]

    def flush(self):
        pass

    def line(self, text):
        self.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [{os.getpid()}] {text}\n")

    def error(self, text):
        self.failed = True
        self.line(text)

    def follow(self, stream):
        """Copy a child's output into the log until it closes."""

        def copy():
            with stream:
                while data := stream.read1(READ_CHUNK):
                    self.write_bytes(data)

        thread = threading.Thread(target=copy, daemon=True)
        thread.start()
        self.readers = [reader for reader in self.readers if reader.is_alive()] + [thread]

    def close(self, timeout=DRAIN_TIMEOUT):
        """Wait up to timeout for the children's output to end, then close; anything later is dropped."""
        deadline = time.monotonic() + timeout
        for reader in self.readers:
            reader.join(max(deadline - time.monotonic(), 0))
        with self.lock:
            self.closed = True
            self.file.close()
        if self.session_lock is not None:
            os.close(self.session_lock)


def held(lock):
    """Whether a live session holds the flock on lock, a session's .lock file."""
    try:
        fd = os.open(lock, os.O_RDWR)
    except FileNotFoundError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def session_log(state, launcher, kept=LOGS_KEPT):
    """Create this session's log, returning its path and the descriptor holding its lock for the session's life.

    The name has a random part, so sessions in other PID namespaces sharing
    this directory never collide. All but the newest kept - 1 earlier logs of
    the same launcher are removed, except those a running session still holds.
    """
    state.mkdir(parents=True, exist_ok=True)
    pattern = re.compile(re.escape(launcher) + r"-\d{8}-\d{6}-[A-Za-z0-9_]+\.log")
    earlier = []
    for path in state.iterdir():
        if pattern.fullmatch(path.name):
            try:
                earlier.append((path.stat().st_mtime, path))
            except FileNotFoundError:
                pass
    earlier.sort()
    for _, old in earlier[: max(len(earlier) - kept + 1, 0)]:
        lock = old.with_suffix(".lock")
        if held(lock):
            continue
        old.unlink(missing_ok=True)
        Path(f"{old}.1").unlink(missing_ok=True)
        lock.unlink(missing_ok=True)
    while True:
        fd, lock = tempfile.mkstemp(prefix=f"{launcher}-{time.strftime('%Y%m%d-%H%M%S')}-", suffix=".lock", dir=state)
        fcntl.flock(fd, fcntl.LOCK_EX)
        path = Path(lock).with_suffix(".log")
        try:
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
            return path, fd
        except FileExistsError:
            os.close(fd)
            os.unlink(lock)


class Ticket:
    """A request's place in the queue; profile None takes whichever profile serves the work ahead of it."""

    def __init__(self, profile):
        self.profile = profile
        self.serving = False


class Backend:
    """One llama-server or strata-server under its own gpu-run, started and stopped only by the main thread.

    Request threads only ask for it, each with a ticket naming the profile its
    model ID selects, or none for the any-profile model. A ticket is served once
    the profile it needs is loaded and no older ticket waits for another one; when the oldest waiting ticket wants another
    profile, the server is unloaded as soon as nothing is being served and the
    new one starts under its own booking. The kernel's parent-death signal
    follows the forking thread, so gpu-run must be forked by the thread that
    outlives the rest.
    """

    def __init__(self, model, label, idle, log, directory, mode="dense"):
        self.model = model
        self.directory = directory
        self.mode = mode
        self.profiles, self.default = profiles(mode)
        self.log = log
        self.label = label
        self.idle = idle
        self.key = secrets.token_hex(24)
        self.port = None
        self.process = None
        self.profile = None
        self.ready = False
        self.error = None
        self.wanted = False
        self.waiting = []
        self.serving = 0
        self.last = time.monotonic()
        self.generation = 0
        self.condition = threading.Condition()
        self.closed = False

    def wants(self, position):
        """The profile the waiting ticket at position needs.

        A ticket for the any-profile model takes the one selected by the work queued
        ahead of it, else the loaded or loading one, else the default.
        """
        for ticket in reversed(self.waiting[: position + 1]):
            if ticket.profile is not None:
                return ticket.profile
        return self.profile or self.default

    def servable(self, ticket):
        if not self.ready:
            return False
        position = self.waiting.index(ticket)
        return all(self.wants(earlier) == self.profile for earlier in range(position + 1))

    def acquire(self, name, timeout):
        """Queue a request for model ID name and wait up to timeout for it. Returns (ticket, ready, error)."""
        with self.condition:
            if not self.waiting and not self.serving and not self.ready:
                self.error = None
            ticket = Ticket(name if name in self.profiles else None)
            self.waiting.append(ticket)
            self.wanted = True
            self.condition.notify_all()
        return (ticket, *self.wait(ticket, timeout))

    def wait(self, ticket, timeout):
        with self.condition:
            self.condition.wait_for(lambda: self.closed or self.error or self.servable(ticket), timeout)
            if self.closed:
                return False, "qwen-opencode is shutting down"
            if self.servable(ticket):
                self.waiting.remove(ticket)
                ticket.serving = True
                self.serving += 1
                return True, None
            return False, self.error

    def release(self, ticket):
        with self.condition:
            if ticket.serving:
                self.serving -= 1
            else:
                self.waiting.remove(ticket)
            self.last = time.monotonic()
            self.condition.notify_all()

    def start(self, name):
        profile = self.profiles[name]
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.generation += 1
        label = self.label if self.mode == "dense" else f"{self.label}, {profile.title}"
        self.log.line(f"requesting a GPU reservation for {label}")
        command = server_command(
            self.model, self.port, self.key, profile.context, self.mode, self.directory, profile.moe
        )
        self.process = subprocess.Popen(
            guarded(
                *(() if self.mode == "dense" else ("--strata-lock",)),
                "gpu-run",
                *profile.booking,
                "--name",
                label,
                "--",
                *guarded(*command),
            ),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.log.follow(self.process.stdout)
        with self.condition:
            self.profile = name

    def unload(self, reason):
        self.log.line(f"unloading Qwen ({reason})")
        with self.condition:
            self.ready = False
        stop(self.process, grace=30)
        self.process = None
        with self.condition:
            self.profile = None
            self.condition.notify_all()

    def tick(self):
        """Advance the backend's state; called repeatedly from the main thread."""
        with self.condition:
            wanted, serving, last = self.wanted, self.serving, self.last
            target = self.wants(0) if self.waiting else None
        if self.process is None:
            if wanted and target is not None:
                self.start(target)
            return
        if self.process.poll() is not None:
            code = self.process.returncode
            self.process = None
            with self.condition:
                self.ready = False
                self.profile = None
                self.wanted = False
                self.error = f"the Qwen server under gpu-run exited with code {code}; see {self.log.name}"
                self.condition.notify_all()
            self.log.error(self.error)
            return
        if target is not None and target != self.profile and serving == 0:
            with self.condition:
                if self.serving:
                    return
                # Under the same lock as the check, so no request can pick up a dying server.
                self.ready = False
            self.unload(f"switching to {target}")
            return
        if not self.ready:
            if healthy(self.port, self.key):
                with self.condition:
                    self.ready = True
                    self.last = time.monotonic()
                    self.condition.notify_all()
                self.log.line(f"Qwen is loaded ({self.profile})")
            return
        if target is None and serving == 0 and time.monotonic() - last >= self.idle:
            with self.condition:
                if self.waiting or self.serving:
                    return
                self.ready = False
                self.wanted = False
            self.unload(f"idle for {self.idle:g}s")

    def close(self):
        with self.condition:
            self.closed = True
            self.condition.notify_all()
        if self.process is not None:
            self.unload("OpenCode exited")


HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "te", "trailer", "upgrade"}


def handler_for(backend, key):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            backend.log.line(f"{self.address_string()} {format % args}")

        def reply(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def chunk(self, data):
            if data:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()

        def end_chunks(self):
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

        def authorized(self):
            if self.headers.get("Authorization") == f"Bearer {key}":
                return True
            self.reply(401, {"error": {"message": "invalid API key", "type": "authentication_error"}})
            return False

        def do_GET(self):
            if not self.authorized():
                return
            # Answer listings without loading the model, so opening OpenCode stays free.
            if self.path.rstrip("/") == "/v1/models":
                models = listed_models(backend.profiles)
                self.reply(
                    200,
                    {
                        "object": "list",
                        "data": [{"id": name, "object": "model", "owned_by": "local"} for name in models],
                    },
                )
            elif self.path == "/health":
                self.reply(200, {"status": "ok"})
            else:
                self.forward(None)

        def do_POST(self):
            if not self.authorized():
                return
            self.forward(self.rfile.read(int(self.headers.get("Content-Length") or 0)))

        def forward(self, body):
            try:
                request = json.loads(body) if body else {}
                streaming = request.get("stream") is True
                name = request.get("model")
            except (ValueError, AttributeError):
                streaming, name = False, None
            started = False
            ticket, ready, error = backend.acquire(name, 0 if streaming else None)
            try:
                if streaming and not ready and not error:
                    # Queued behind other GPU work: commit to an event stream and keep it
                    # alive with comments so the client's header timeout never fires.
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    started = True
                    while not ready and not error:
                        self.chunk(b": waiting for a GPU reservation\n\n")
                        ready, error = backend.wait(ticket, KEEPALIVE)
                if not ready:
                    raise ConnectionError(error)
                self.relay(body, started)
            except DISCONNECTS:
                pass
            except (OSError, http.client.HTTPException) as failure:
                message = str(failure) or "the Qwen server is unavailable"
                backend.log.error(f"{self.command} {self.path}: {message}")
                if started:
                    payload = {"error": {"message": message, "type": "server_error"}}
                    self.chunk(b"data: " + json.dumps(payload).encode() + b"\n\n")
                    self.end_chunks()
                else:
                    self.reply(503, {"error": {"message": message, "type": "server_error"}})
            finally:
                backend.release(ticket)

        def relay(self, body, started):
            upstream = http.client.HTTPConnection("127.0.0.1", backend.port, timeout=None)
            try:
                headers = {"Authorization": f"Bearer {backend.key}"}
                if body is not None:
                    headers["Content-Type"] = self.headers.get("Content-Type", "application/json")
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                if started:
                    if response.status != 200:
                        detail = response.read().decode("utf-8", "replace")
                        raise ConnectionError(f"Qwen returned HTTP {response.status}: {detail}")
                else:
                    self.send_response(response.status)
                    for name, value in response.getheaders():
                        if name.lower() not in HOP_BY_HOP:
                            self.send_header(name, value)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                while data := response.read1(65536):
                    self.chunk(data)
                self.end_chunks()
            finally:
                upstream.close()

    return Handler


class Proxy(http.server.ThreadingHTTPServer):
    """Logs failures to the session log, since socketserver would print them over OpenCode's TUI."""

    daemon_threads = True

    def __init__(self, address, handler, log):
        self.log = log
        super().__init__(address, handler)

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if isinstance(error, DISCONNECTS):
            return
        self.log.error(
            f"request from {client_address[0]}:{client_address[1]} failed\n" + traceback.format_exc().rstrip()
        )


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, allow_abbrev=False, usage="%(prog)s [--uncensored] [--moe] [opencode args...]"
    )
    parser.add_argument("--uncensored", action="store_true", help="Use the uncensored Qwen variant")
    parser.add_argument(
        "--moe",
        action="store_true",
        help="Serve Qwen3.8-Flash-Next through Strata, with the experts the GPU doesn't hold in system RAM, instead "
        "of the dense 27B at 64k. OpenCode's model list picks a VRAM profile: 20G at 256k (the default), 16G at "
        "256k, 12G at 128k or 8G at 64k; picking another one reloads Strata",
    )
    parser.add_argument(
        "--idle-minutes",
        type=float,
        default=float(os.environ.get("QWEN_OPENCODE_IDLE_MINUTES", "5")),
        help="Unload Qwen and release the GPU after this long without requests (default 5)",
    )
    # Only leading options are this launcher's; everything from the first other
    # argument on, such as a prompt Orca passes, goes to OpenCode untouched.
    argv = sys.argv[1:]
    own = 0
    while own < len(argv):
        if argv[own] == "--strata":
            parser.error("--strata is gone: --moe now serves Qwen3.8-Flash-Next through Strata")
        if argv[own] in ("--uncensored", "--moe", "-h", "--help") or argv[own].startswith("--idle-minutes="):
            own += 1
        elif argv[own] == "--idle-minutes":
            own += 2
        else:
            break
    args = parser.parse_args(argv[:own])
    opencode_args = argv[own:]
    if args.idle_minutes <= 0:
        parser.error("--idle-minutes must be positive")
    name = "uncensored" if args.uncensored else "regular"
    mode = mode_of(args)
    require("opencode", server_binary(mode), "gpu-run")
    model = resolve_model(name, mode)
    refuse_nesting()
    major = checked_opencode_major()
    alias = model_alias(name, mode)
    if mode == "moe":
        strata_pack(model)
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "qwen-prompt"
    # OpenCode shares the terminal's foreground group and decides what Ctrl-C means;
    # cleanup follows its exit. A handler, unlike SIG_IGN, is not inherited.
    signal.signal(signal.SIGINT, lambda _signum, _frame: None)
    harness = None

    def interrupted(signum, _frame):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda _signum, _frame: None)
        if harness is not None and harness.poll() is None:
            harness.send_signal(signum)
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    key = secrets.token_hex(24)
    path, session_lock = session_log(state, f"qwen-opencode-{name}{'' if mode == 'dense' else '-' + mode}")
    log = Log(path, session_lock=session_lock)
    threading.excepthook = lambda hook: log.error(
        "".join(traceback.format_exception(hook.exc_type, hook.exc_value, hook.exc_traceback)).rstrip()
    )
    print(
        f"qwen-opencode: {alias} loads on demand and unloads after {args.idle_minutes:g} min idle",
        file=sys.stderr,
        flush=True,
    )
    with tempfile.TemporaryDirectory(prefix="qwen-opencode-") as directory:
        label = f"Qwen OpenCode ({name}{'' if mode == 'dense' else ', ' + mode})"
        backend = Backend(model, label, args.idle_minutes * 60, log, directory, mode)
        proxy = Proxy(("127.0.0.1", 0), handler_for(backend, key), log)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        models = listed_models(backend.profiles)
        env = opencode_environment(configuration(proxy.server_port, major, models, backend.default), key, directory)
        try:
            harness = subprocess.Popen(guarded("opencode", "--standalone", *opencode_args), env=env)
            while harness.poll() is None:
                backend.tick()
                with backend.condition:
                    backend.condition.wait(0.5)
            return harness.returncode
        finally:
            backend.close()
            proxy.shutdown()
            proxy.server_close()
            if harness is not None and harness.poll() is None:
                harness.terminate()
                try:
                    harness.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    harness.kill()
                    harness.wait()
            log.close()
            if log.failed:
                print(f"qwen-opencode: errors were logged to {log.name}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"qwen-opencode: {error}", file=sys.stderr)
        sys.exit(1)
