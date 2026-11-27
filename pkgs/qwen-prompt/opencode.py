"""Interactive OpenCode on local Qwen, loading the model on demand and unloading it when idle."""

import argparse
import http.client
import http.server
import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
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


class Ticket:
    def __init__(self, profile):
        self.profile = profile
        self.serving = False


class Backend:
    """One llama-server or strata-server under its own gpu-run, started and stopped only by the main thread.

    Request threads only ask for it, each with a ticket naming the profile its
    model ID selects. A ticket is served once that profile is loaded and no older
    ticket waits for another one; when the oldest waiting ticket wants another
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

    def servable(self, ticket):
        if not self.ready or self.profile != ticket.profile:
            return False
        return all(other.profile == ticket.profile for other in self.waiting[: self.waiting.index(ticket)])

    def acquire(self, name, timeout):
        """Queue a request for model ID name and wait up to timeout for it. Returns (ticket, ready, error)."""
        with self.condition:
            if not self.waiting and not self.serving and not self.ready:
                self.error = None
            if name in self.profiles:
                profile = name
            elif self.profile is not None:
                profile = self.profile
            else:
                profile = self.waiting[0].profile if self.waiting else self.default
            ticket = Ticket(profile)
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
        print(f"qwen-opencode: requesting a GPU reservation for {label}", file=self.log, flush=True)
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
            stdout=self.log,
            stderr=self.log,
            start_new_session=True,
        )
        with self.condition:
            self.profile = name

    def unload(self, reason):
        print(f"qwen-opencode: unloading Qwen ({reason})", file=self.log, flush=True)
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
            target = self.waiting[0].profile if self.waiting else None
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
            print(f"qwen-opencode: {self.error}", file=self.log, flush=True)
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
                print(f"qwen-opencode: Qwen is loaded ({self.profile})", file=self.log, flush=True)
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

        def log_message(self, *args):
            pass

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
            except (BrokenPipeError, ConnectionResetError):
                pass
            except (OSError, http.client.HTTPException) as failure:
                message = str(failure) or "the Qwen server is unavailable"
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
    daemon_threads = True


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
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "qwen-opencode"
    state.mkdir(parents=True, exist_ok=True)
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
    with (
        tempfile.TemporaryDirectory(prefix="qwen-opencode-") as directory,
        open(state / f"{os.getpid()}.log", "w", buffering=1) as log,
    ):
        label = f"Qwen OpenCode ({name}{'' if mode == 'dense' else ', ' + mode})"
        backend = Backend(model, label, args.idle_minutes * 60, log, directory, mode)
        proxy = Proxy(("127.0.0.1", 0), handler_for(backend, key))
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        print(
            f"qwen-opencode: {alias} loads on demand and unloads after {args.idle_minutes:g} min idle; log {log.name}",
            file=sys.stderr,
            flush=True,
        )
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
            if backend.error is None:
                Path(log.name).unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"qwen-opencode: {error}", file=sys.stderr)
        sys.exit(1)
