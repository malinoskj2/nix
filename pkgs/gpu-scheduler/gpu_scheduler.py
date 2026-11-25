"""Cooperative, single-GPU admission control shared by host and containers."""

import argparse
import contextlib
import ctypes
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class Scheduler:
    def __init__(self, directory, headroom=4096):
        self.directory = Path(directory)
        self.headroom = headroom
        if "AGENT_SANDBOX_INSTANCE" in os.environ and not self.directory.is_dir():
            raise RuntimeError("GPU lease directory is not mounted; restart the sandbox after updating the host")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.mutex = os.open(self.directory / "admission.lock", os.O_CREAT | os.O_RDWR, 0o600)

    @contextlib.contextmanager
    def locked(self):
        fcntl.flock(self.mutex, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(self.mutex, fcntl.LOCK_UN)

    def jobs(self, own_id=None):
        """Caller holds admission.lock. Unlocked records belong to dead workloads."""
        jobs = []
        for path in sorted(self.directory.glob("*.json")):
            with path.open("r+") as record:
                if path.stem != own_id:
                    try:
                        fcntl.flock(record, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        pass
                    else:
                        path.unlink()
                        continue
                jobs.append(json.load(record))
        return jobs

    def enqueue(self, mode, vram, label, game):
        job = {
            "id": uuid.uuid4().hex,
            "label": label,
            "origin": os.environ.get("AGENT_SANDBOX_INSTANCE") or "host",
            "pid": os.getpid(),
            "mode": mode,
            "vram_mib": vram,
            "game": game,
            "created_ns": time.time_ns(),
            "state": "waiting",
        }
        with self.locked():
            fd = os.open(self.directory / f"{job['id']}.json", os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            self.write(fd, job)
        return job, fd

    @staticmethod
    def write(fd, job):
        data = json.dumps(job).encode()
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, data)
        os.ftruncate(fd, len(data))


def admission_reason(job, jobs, memory, headroom, allocations=None):
    total, used = memory
    capacity = total - headroom
    requested = capacity if job["mode"] == "exclusive" else job["vram_mib"]
    if requested > capacity or capacity <= 0:
        raise ValueError(f"Reservation exceeds usable VRAM ({max(0, capacity)} MiB after desktop headroom)")
    active = [item for item in jobs if item["state"] == "running"]
    waiting = sorted(
        (item for item in jobs if item["state"] == "waiting"),
        key=lambda item: (not item["game"], item["created_ns"], item["id"]),
    )
    if waiting[0]["id"] != job["id"]:
        return f"behind {waiting[0]['label']} in the queue"
    if any(item["mode"] == "exclusive" for item in active):
        return "an exclusive workload holds the GPU"
    if job["mode"] == "exclusive":
        if active:
            return "waiting for active shared workloads to finish and unload"
        if used > headroom:
            return f"{used} MiB still in use; exclusive admission needs at most {headroom} MiB in use"
    else:
        reserved = sum(item["vram_mib"] for item in active)
        # Credit only memory attributed to a live lease. Keep each lease's unused
        # peak budget reserved for inference, and charge overruns in full.
        allocations = allocations or {}
        managed = sum(allocations.get(item["id"], 0) for item in active)
        peaks = sum(max(item["vram_mib"], allocations.get(item["id"], 0)) for item in active)
        unmanaged = max(headroom, used - managed)
        if unmanaged + peaks + requested > total:
            return (
                f"insufficient VRAM ({used} MiB measured, {managed} MiB attributed, "
                f"{reserved} MiB reserved, {unmanaged} MiB outside leases/headroom)"
            )
    return None


def gpu_memory():
    result = subprocess.run(
        ["nvidia-smi", "--id=0", "--query-gpu=memory.total,memory.used", "--format=csv,noheader,nounits"],
        check=True,
        capture_output=True,
        text=True,
        timeout=3,
    )
    total, used = (int(value.strip()) for value in result.stdout.strip().split(","))
    if total <= 0 or not 0 <= used <= total:
        raise ValueError("Invalid GPU memory telemetry")
    return total, used


def host_gpu_snapshot():
    """Read host PIDs: container /proc cannot identify other containers' GPU workers."""
    result = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=gpu_uuid,pid,used_gpu_memory", "--format=csv,noheader,nounits"],
        check=True, capture_output=True, text=True, timeout=3,
    )
    processes = result.stdout.splitlines()
    result = subprocess.run(
        ["nvidia-smi", "--id=0", "--query-gpu=uuid,memory.total,memory.used", "--format=csv,noheader,nounits"],
        check=True, capture_output=True, text=True, timeout=3,
    )
    gpu, total, used = (value.strip() for value in result.stdout.strip().split(","))
    allocations = {}
    seen = set()
    for row in processes:
        if not row.strip():
            continue
        device, pid, amount = (value.strip() for value in row.split(","))
        if device != gpu:
            continue
        # Missing per-process metrics grant no credit; aggregate usage still counts.
        if not pid.isdecimal() or not amount.isdecimal() or pid in seen:
            continue
        seen.add(pid)
        try:
            path = Path("/proc") / pid
            if path.stat().st_uid != os.getuid():
                continue
            with (path / "environ").open("rb") as environment:
                fields = environment.read(1024 * 1024).split(b"\0")
        except OSError:
            continue
        lease = next((field[13:].decode("ascii", errors="replace") for field in fields
                      if field.startswith(b"GPU_LEASE_ID=")), "")
        if re.fullmatch(r"[0-9a-f]{32}", lease):
            allocations[lease] = allocations.get(lease, 0) + int(amount)
    return validate_snapshot({"total_mib": int(total), "used_mib": int(used), "allocations_mib": allocations})


def validate_snapshot(value):
    total, used, allocations = value["total_mib"], value["used_mib"], value["allocations_mib"]
    if (type(total) is not int or type(used) is not int or total <= 0 or not 0 <= used <= total
            or not isinstance(allocations, dict)
            or any(not re.fullmatch(r"[0-9a-f]{32}", key) or type(amount) is not int or amount < 0
                   for key, amount in allocations.items())
            or sum(allocations.values()) > used):
        raise ValueError("Invalid GPU attribution telemetry")
    return value


def gpu_snapshot(scheduler):
    """An unavailable/older host falls back to double-counting, never optimistic admission."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(8)
            client.connect(str(scheduler.directory / "telemetry.sock"))
            data = bytearray()
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > 1024 * 1024:
                    raise ValueError("GPU telemetry response exceeds limit")
        value = validate_snapshot(json.loads(data))
        return (value["total_mib"], value["used_mib"]), value["allocations_mib"]
    except (OSError, ValueError, KeyError, TypeError):
        return gpu_memory(), None


def serve_telemetry():
    # systemd owns the socket and its permissions. No client commands or paths are accepted.
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
        raise RuntimeError("GPU telemetry requires its systemd user socket")
    with socket.socket(fileno=3) as listener:
        while True:
            client, _ = listener.accept()
            with client:
                client.settimeout(8)
                try:
                    value = host_gpu_snapshot()
                except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
                    value = {"error": str(error)}
                try:
                    client.sendall(json.dumps(value).encode())
                except OSError:
                    pass


def memory_size(value):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)(MiB|GiB)", value, re.IGNORECASE)
    if not match:
        raise argparse.ArgumentTypeError("Use a positive size such as 4096MiB or 4GiB")
    amount = math.ceil(float(match[1]) * (1024 if match[2].lower() == "gib" else 1))
    if amount <= 0:
        raise argparse.ArgumentTypeError("VRAM must be positive")
    return amount


class OrcaWorker:
    """An Orca worker's own mailbox: a held waiter makes its idle turn a deliberate wait, mail wakes it."""

    # A filtered waiter leaves every other message to Orca's normal delivery; workers never receive this type.
    HOLD_TYPE = "merge_ready"

    def __init__(self, cli, sender, dispatch):
        self.cli, self.sender, self.dispatch = cli, sender, dispatch
        self.stopped = threading.Event()
        self.waiter = None

    @classmethod
    def detect(cls, dispatch=None, sender=None):
        cli = os.environ.get("ORCA_CLI_COMMAND") or shutil.which("orca") or shutil.which("orca-ide")
        session = os.environ.get("ORCA_AGENT_SESSION_ID")
        sender = sender or (f"orca_session_id:{session}" if session else os.environ.get("ORCA_TERMINAL_HANDLE"))
        if not cli or not sender:
            return None
        if not dispatch:
            try:
                out = subprocess.run(
                    [cli, "orchestration", "check", "--peek", "--json", "--full"],
                    capture_output=True, text=True, timeout=30, check=True,
                )
                dispatch = json.loads(out.stdout)["result"].get("dispatchId")
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError):
                return None
        return cls(cli, sender, dispatch) if dispatch else None

    def hold(self):
        def loop():
            while not self.stopped.is_set():
                started = time.monotonic()
                self.waiter = subprocess.Popen(
                    [self.cli, "orchestration", "check", "--peek", "--wait", "--types", self.HOLD_TYPE,
                     "--timeout-ms", "300000", "--json"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                self.waiter.wait()
                if time.monotonic() - started < 5:
                    self.stopped.wait(5)

        threading.Thread(target=loop, daemon=True).start()

    def release(self):
        self.stopped.set()
        if self.waiter and self.waiter.poll() is None:
            self.waiter.terminate()

    def wake(self, subject, body):
        try:
            subprocess.run(
                [self.cli, "orchestration", "send", "--from", self.sender, "--to", f"dispatch:{self.dispatch}",
                 "--type", "status", "--subject", subject, "--body", body],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
            )
        except (OSError, subprocess.SubprocessError) as error:
            print(f"gpu-run: could not wake the Orca worker: {error}", file=sys.stderr, flush=True)


def log_tail(path, limit=1500):
    try:
        with open(path, "rb") as f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - limit))
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def own_job(scheduler, pid):
    with scheduler.locked():
        return next((job for job in scheduler.jobs() if job["pid"] == pid), None)


def launch_background(args, label):
    worker = OrcaWorker.detect(args.orca_dispatch)
    if not worker:
        raise RuntimeError(
            "--background needs an Orca worker mailbox to wake; outside Orca, run gpu-run itself as a background command"
        )
    log = Path(args.log or Path(tempfile.gettempdir()) / f"gpu-run-{uuid.uuid4().hex[:8]}.log").resolve()
    options, command = split_argv(args, drop_flags={"--background"}, drop_valued={"--orca-dispatch", "--log"})
    ready, report = os.pipe()
    with open(log, "ab") as output:
        coordinator = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), *options,
             "--daemon-ready-fd", str(report), "--orca-dispatch", worker.dispatch, "--orca-from", worker.sender,
             "--log", str(log), *command],
            stdin=subprocess.DEVNULL, stdout=output, stderr=output, pass_fds=(report,), start_new_session=True,
        )
    os.close(report)
    with os.fdopen(ready) as reader:
        lease = reader.read().strip()
    if not lease:
        raise RuntimeError(f"background reservation failed to queue; see {log}\n{log_tail(log)}")
    print(
        f"gpu-run: queued {label} as lease {lease[:8]} (cancel with: kill {coordinator.pid}); log {log}\n"
        f"gpu-run: Orca will message dispatch {worker.dispatch} when it finishes; you may end your turn",
        flush=True,
    )
    return 0


def split_argv(args, drop_flags=(), drop_valued=()):
    """This invocation's options and command, without the given options."""
    tail = len(args.command)
    options, skip = [], False
    for token in sys.argv[1:len(sys.argv) - tail]:
        if skip:
            skip = False
        elif token in drop_valued:
            skip = True
        elif token not in drop_flags and not any(token.startswith(f"{name}=") for name in drop_valued):
            options.append(token)
    return options, sys.argv[len(sys.argv) - tail:]


def run_background(scheduler, args, label):
    """Holds the worker's wait outside the lease's supervisor, whose subreaper would adopt the waiter."""
    worker = OrcaWorker.detect(args.orca_dispatch, args.orca_from)
    if not worker:
        raise RuntimeError("Orca worker mailbox unavailable")
    options, command = split_argv(
        args,
        drop_flags={"--wake-on-grant"},
        drop_valued={"--daemon-ready-fd", "--orca-dispatch", "--orca-from", "--log"},
    )
    started = time.monotonic()
    outcome = "stopped before finishing"
    job = None
    worker.hold()
    child = subprocess.Popen([sys.executable, os.path.abspath(__file__), *options, *command], stdin=subprocess.DEVNULL)

    def forward(signum, _frame):
        child.send_signal(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    try:
        deadline = time.monotonic() + 30
        while job is None and child.poll() is None and time.monotonic() < deadline:
            job = own_job(scheduler, child.pid)
            time.sleep(0.1)
        # Let the waiter register before the agent's turn can end.
        time.sleep(1.5)
        with os.fdopen(args.daemon_ready_fd, "w") as ready:
            ready.write(job["id"] if job else "")
        granted = False
        while child.poll() is None:
            current = own_job(scheduler, child.pid)
            if not granted and current and current["state"] == "running":
                granted = True
                print(f"gpu-run: lease {current['id'][:8]} granted", flush=True)
                if args.wake_on_grant:
                    worker.wake(f"gpu-run granted: {label}", f"The reservation started and the command is running. Log: {args.log}")
            time.sleep(1)
        code = child.returncode if child.returncode >= 0 else 128 - child.returncode
        outcome = f"exit {code}"
        return code
    finally:
        worker.release()
        if job:
            minutes = (time.monotonic() - started) / 60
            worker.wake(
                f"gpu-run finished: {label} ({outcome})",
                f"{minutes:.1f} min including the queue. Log: {args.log}\nLast output:\n{log_tail(args.log)}",
            )


def run(scheduler, args):
    if os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("Already inside a GPU reservation; run the workload directly instead of nesting gpu-run")
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("Supply a foreground command after --")
    mode = "exclusive" if args.exclusive else "shared"
    label = args.name or shlex.join(command)[:160]
    if args.background:
        return launch_background(args, label)
    if args.daemon_ready_fd is not None:
        return run_background(scheduler, args, label)
    job, fd = scheduler.enqueue(mode, args.vram, label, args.action == "game")
    last_reason = None
    started = time.monotonic()
    try:
        while True:
            # Probe inside the admission mutex so a second grant cannot use a snapshot
            # taken before an earlier grant. It remains advisory against bypassing apps.
            with scheduler.locked():
                jobs = scheduler.jobs(job["id"])
                try:
                    memory, allocations = gpu_snapshot(scheduler)
                except (OSError, subprocess.SubprocessError, ValueError) as error:
                    reason = f"GPU telemetry unavailable: {error}"
                else:
                    reason = admission_reason(job, jobs, memory, scheduler.headroom, allocations)
                if reason is None:
                    job["state"] = "running"
                    scheduler.write(fd, job)
            if reason is None:
                break
            if reason != last_reason:
                print(f"gpu-run: waiting: {reason}", file=sys.stderr, flush=True)
                last_reason = reason
            if args.timeout is not None and time.monotonic() - started >= args.timeout:
                raise TimeoutError("Timed out waiting for a GPU reservation")
            time.sleep(0.5)
        print(f"gpu-run: granted {mode} reservation for {label}", file=sys.stderr, flush=True)
        return supervise(command, fd, job["id"])
    finally:
        os.close(fd)
        # Never unlink a live lease; stale records are reaped under the global mutex.


def supervise(command, fd, lease_id):
    # Steam/Proton and model servers may detach workers or close inherited FDs.
    # Adopt descendants and hold the lease until the last child has exited.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "Cannot supervise GPU workload descendants")
    process = subprocess.Popen(
        command,
        start_new_session=True,
        pass_fds=(fd,),
        env={**os.environ, "GPU_LEASE_ID": lease_id},
    )

    def forward(signum, _frame):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    result = 0
    try:
        while True:
            try:
                pid, child_status = os.wait()
            except ChildProcessError:
                break
            if pid == process.pid:
                process.returncode = os.waitstatus_to_exitcode(child_status)
                result = process.returncode
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return result if result >= 0 else 128 - result


def status(scheduler, as_json):
    with scheduler.locked():
        jobs = scheduler.jobs()
        try:
            (total, used), allocations = gpu_snapshot(scheduler)
            attribution_available = allocations is not None
            allocations = allocations or {}
            memory = {
                "total_mib": total, "used_mib": used, "headroom_mib": scheduler.headroom,
                "attributed_mib": sum(allocations.get(job["id"], 0) for job in jobs if job["state"] == "running"),
                "attribution_available": attribution_available,
            }
            error = None
        except (OSError, subprocess.SubprocessError, ValueError) as problem:
            memory, error = None, str(problem)
        for job in jobs:
            if memory:
                job["allocated_mib"] = allocations.get(job["id"], 0)
            if job["state"] == "waiting" and memory:
                try:
                    job["reason"] = admission_reason(job, jobs, (total, used), scheduler.headroom, allocations)
                except ValueError as problem:
                    job["reason"] = str(problem)
            elif job["state"] == "waiting":
                job["reason"] = "GPU telemetry unavailable"
    if as_json:
        print(json.dumps({"memory": memory, "telemetry_error": error, "jobs": jobs}, indent=2))
        return
    if memory:
        print(f"GPU 0: {used}/{total} MiB in use; {scheduler.headroom} MiB desktop headroom")
        if not memory["attribution_available"]:
            print("Host attribution unavailable; using conservative aggregate accounting.")
    else:
        print(f"GPU telemetry unavailable: {error}")
    for job in sorted(jobs, key=lambda item: (item["state"] != "running", not item["game"], item["created_ns"])):
        budget = "exclusive" if job["mode"] == "exclusive" else f"{job['vram_mib']} MiB"
        print(f"{job['state']:7} {job['id'][:8]} {budget:12} {job['label']} ({job['origin']}, PID {job['pid']})")
        if job.get("allocated_mib"):
            print(f"        {job['allocated_mib']} MiB attributed to this lease")
        if job.get("reason"):
            print(f"        {job['reason']}")
    if not jobs:
        print("No active or queued reservations.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    for name in ("run", "game"):
        action = actions.add_parser(name)
        mode = action.add_mutually_exclusive_group(required=name == "run")
        mode.add_argument("--exclusive", action="store_true", default=name == "game")
        if name == "run":
            mode.add_argument("--vram", type=memory_size, help="Peak VRAM including weights, inference caches and working memory")
        action.set_defaults(vram=None)
        action.add_argument("--name", help="Human-readable workload name")
        action.add_argument("--timeout", type=float, help="Maximum queue wait in seconds")
        action.add_argument(
            "--background", action="store_true",
            help="Return at once; an Orca worker's idle turn counts as waiting and Orca mails it the result",
        )
        action.add_argument("--wake-on-grant", action="store_true", help="With --background, also mail when granted")
        action.add_argument("--log", help="With --background, where the command's output goes")
        action.add_argument("--orca-dispatch", help="With --background, the worker's Dispatch ID (default: detected)")
        action.add_argument("--orca-from", help=argparse.SUPPRESS)
        action.add_argument("--daemon-ready-fd", type=int, help=argparse.SUPPRESS)
        action.add_argument("command", nargs=argparse.REMAINDER)
    actions.add_parser("status").add_argument("--json", action="store_true")
    actions.add_parser("serve-telemetry")
    args = parser.parse_args()
    if args.action == "serve-telemetry":
        serve_telemetry()
        return
    # A single deployment setting, never a per-request override that agents can lower.
    directory = os.environ.get("GPU_SCHEDULER_DIR", f"/run/user/{os.getuid()}/gpu-scheduler")
    scheduler = Scheduler(directory)
    if args.action == "status":
        status(scheduler, args.json)
    else:
        return run(scheduler, args)


if __name__ == "__main__":
    # Interrupted queued requests release their lease without an exception traceback.
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(143))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        print(f"gpu-run: {error}", file=sys.stderr)
        sys.exit(1)
