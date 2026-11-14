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


def admission_reason(job, jobs, memory, headroom):
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
        # Existing grants may still allocate their full budget, while measured usage
        # may belong to unmanaged processes. Without reliable per-lease attribution,
        # count both conservatively rather than risk granting the same memory twice.
        if max(used, headroom) + reserved + requested > total:
            return f"insufficient VRAM ({used} MiB measured, {reserved} MiB reserved, {headroom} MiB headroom)"
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
                    memory = gpu_memory()
                except (OSError, subprocess.SubprocessError, ValueError) as error:
                    reason = f"GPU telemetry unavailable: {error}"
                else:
                    reason = admission_reason(job, jobs, memory, scheduler.headroom)
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
            total, used = gpu_memory()
            memory = {"total_mib": total, "used_mib": used, "headroom_mib": scheduler.headroom}
            error = None
        except (OSError, subprocess.SubprocessError, ValueError) as problem:
            memory, error = None, str(problem)
        for job in jobs:
            if job["state"] == "waiting" and memory:
                try:
                    job["reason"] = admission_reason(job, jobs, (total, used), scheduler.headroom)
                except ValueError as problem:
                    job["reason"] = str(problem)
            elif job["state"] == "waiting":
                job["reason"] = "GPU telemetry unavailable"
    if as_json:
        print(json.dumps({"memory": memory, "telemetry_error": error, "jobs": jobs}, indent=2))
        return
    if memory:
        print(f"GPU 0: {used}/{total} MiB in use; {scheduler.headroom} MiB desktop headroom")
    else:
        print(f"GPU telemetry unavailable: {error}")
    for job in sorted(jobs, key=lambda item: (item["state"] != "running", not item["game"], item["created_ns"])):
        budget = "exclusive" if job["mode"] == "exclusive" else f"{job['vram_mib']} MiB"
        print(f"{job['state']:7} {job['id'][:8]} {budget:12} {job['label']} ({job['origin']}, PID {job['pid']})")
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
            mode.add_argument("--vram", type=memory_size)
        action.set_defaults(vram=None)
        action.add_argument("--name", help="Human-readable workload name")
        action.add_argument("--timeout", type=float, help="Maximum queue wait in seconds")
        action.add_argument("command", nargs=argparse.REMAINDER)
    actions.add_parser("status").add_argument("--json", action="store_true")
    args = parser.parse_args()
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
