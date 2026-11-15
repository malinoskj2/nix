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
import signal
import socket
import subprocess
import sys
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
