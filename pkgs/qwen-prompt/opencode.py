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
from pathlib import Path

from qwen_local import (
    STRATA_BOOKING,
    checked_opencode_major,
    configuration,
    guarded,
    healthy,
    mode_of,
    model_alias,
    opencode_environment,
    refuse_nesting,
    require,
    resolve_model,
    server_binary,
    server_command,
    stop,
    strata_tokenizer,
)

CONTEXT = 65536
# Hybrid Qwen3.8 27B: 16 of 65 layers use attention, 4 KV heads of 256, so an
# f16 KV cache costs 64 KiB per token, 4 GiB at 64k. Regular weights are
# 19.5 GiB; measured peak with a full context is in docs/gpu-scheduler.md.
BOOKING = ("--vram", "26GiB")
# Qwen3.6-35B-A3B on llama.cpp, all on the GPU: 10 attention layers with 2 KV heads
# of 256 make the f16 cache 20 KiB per token, 5 GiB at 256k. With a 234k-token prompt
# UD-Q4_K_XL peaked at 27,129 MiB above the desktop baseline (the abliterated Q4_K at
# 26,351), under the 28,511 MiB a shared request may take.
MOE_BOOKING = ("--vram", "28000MiB")
MODES = {
    "dense": (CONTEXT, BOOKING),
    "moe": (262144, MOE_BOOKING),
    "strata": (262144, STRATA_BOOKING),
}
KEEPALIVE = 15


class Backend:
    """One llama-server under its own gpu-run, started and stopped only by the main thread.

    Request threads only ask for it. The kernel's parent-death signal follows the
    forking thread, so gpu-run must be forked by the thread that outlives the rest.
    """

    def __init__(self, model, label, idle, log, directory, mode="dense"):
        self.model = model
        self.directory = directory
        self.mode = mode
        self.context, self.booking = MODES[mode]
        self.log = log
        self.label = label
        self.idle = idle
        self.key = secrets.token_hex(24)
        self.port = None
        self.process = None
        self.ready = False
        self.error = None
        self.wanted = False
        self.inflight = 0
        self.last = time.monotonic()
        self.generation = 0
        self.condition = threading.Condition()
        self.closed = False

    def acquire(self, timeout):
        """Count a request and wait up to timeout for a serving backend. Returns (ready, error)."""
        with self.condition:
            if self.inflight == 0 and not self.ready:
                self.error = None
            self.inflight += 1
            self.wanted = True
            self.condition.notify_all()
            self.condition.wait_for(lambda: self.ready or self.error or self.closed, timeout)
            if self.closed:
                return False, "qwen-opencode is shutting down"
            return self.ready, self.error

    def wait(self, timeout):
        with self.condition:
            self.condition.wait_for(lambda: self.ready or self.error or self.closed, timeout)
            if self.closed:
                return False, "qwen-opencode is shutting down"
            return self.ready, self.error

    def release(self):
        with self.condition:
            self.inflight -= 1
            self.last = time.monotonic()
            self.condition.notify_all()

    def start(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.generation += 1
        print(f"qwen-opencode: requesting a GPU reservation for {self.label}", file=self.log, flush=True)
        self.process = subprocess.Popen(
            guarded(
                "gpu-run",
                *self.booking,
                "--name",
                self.label,
                "--",
                *guarded(*server_command(self.model, self.port, self.key, self.context, self.mode, self.directory)),
            ),
            stdin=subprocess.DEVNULL,
            stdout=self.log,
            stderr=self.log,
            start_new_session=True,
        )

    def unload(self, reason):
        print(f"qwen-opencode: unloading Qwen ({reason})", file=self.log, flush=True)
        with self.condition:
            self.ready = False
        stop(self.process, grace=30)
        self.process = None

    def tick(self):
        """Advance the backend's state; called repeatedly from the main thread."""
        with self.condition:
            wanted, inflight, last = self.wanted, self.inflight, self.last
        if self.process is None:
            if wanted:
                self.start()
            return
        if self.process.poll() is not None:
            code = self.process.returncode
            self.process = None
            with self.condition:
                self.ready = False
                self.wanted = False
                self.error = f"the Qwen server under gpu-run exited with code {code}; see {self.log.name}"
                self.condition.notify_all()
            print(f"qwen-opencode: {self.error}", file=self.log, flush=True)
            return
        if not self.ready:
            if healthy(self.port, self.key):
                with self.condition:
                    self.ready = True
                    self.last = time.monotonic()
                    self.condition.notify_all()
                print("qwen-opencode: Qwen is loaded", file=self.log, flush=True)
            return
        if inflight == 0 and time.monotonic() - last >= self.idle:
            with self.condition:
                if self.inflight:
                    return
                # Under the same lock as the check, so no request can pick up a dying server.
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
                self.reply(200, {"object": "list", "data": [{"id": "qwen", "object": "model", "owned_by": "local"}]})
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
                streaming = bool(body) and json.loads(body).get("stream") is True
            except (ValueError, AttributeError):
                streaming = False
            started = False
            ready, error = backend.acquire(0 if streaming else None)
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
                        ready, error = backend.wait(KEEPALIVE)
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
                backend.release()

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
        description=__doc__, allow_abbrev=False, usage="%(prog)s [--uncensored] [--moe | --strata] [opencode args...]"
    )
    parser.add_argument("--uncensored", action="store_true", help="Use the uncensored Qwen variant")
    backends = parser.add_mutually_exclusive_group()
    backends.add_argument(
        "--moe",
        action="store_true",
        help="Serve Qwen3.6-35B-A3B with llama.cpp at 256k, all on the GPU, instead of the dense 27B at 64k",
    )
    backends.add_argument(
        "--strata",
        action="store_true",
        help="Serve Qwen3.6-35B-A3B through Strata at 256k, with experts that don't fit in VRAM in system RAM; books the whole GPU",
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
        if argv[own] in ("--uncensored", "--moe", "--strata", "-h", "--help") or argv[own].startswith(
            "--idle-minutes="
        ):
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
    if mode == "strata":
        strata_tokenizer(model)
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
        env = opencode_environment(configuration(proxy.server_port, major, backend.context), key, directory)
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
