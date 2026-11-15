"""Slurm is the allocation and process-lifetime authority; this service gates release."""

import argparse
import contextlib
import ctypes
import fcntl
import json
import math
import os
from pathlib import Path
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid

VERSION = 1
MAX_MESSAGE = 1024 * 1024
TERMINAL = {"completed", "failed", "cancelled"}
ACTIVE = {"pending", "running", "unknown"}
DEFAULTS = dict(
    socket_path="/run/resource-scheduler/control.sock",
    state_dir="/var/lib/resource-scheduler",
    allowed_uid=1000,
    allowed_gid=100,
    partition="resource",
    cpu_capacity=12,
    ram_headroom_mib=4096,
    vram_headroom_mib=3072,
    gpu_capacity_mib=32768,
    poll_seconds=2,
    stability_seconds=10,
    history_limit=500,
    policy_version="1",
    game_cpu_capacity=4,
    game_marker_path="/run/resource-scheduler-game-active",
    cgroup_root="/sys/fs/cgroup",
)
TOOL_PATH = "@resourceToolPath@"
SAFE_ENV = {
    "PATH": TOOL_PATH if not TOOL_PATH.startswith("@") else "/run/current-system/sw/bin:/usr/bin:/bin",
    "LANG": "C.UTF-8",
}
# This value comes from the trusted systemd unit, never the submitted payload.
if os.environ.get("SLURM_CONF"):
    SAFE_ENV["SLURM_CONF"] = os.environ["SLURM_CONF"]
ID_RE = re.compile(r"[0-9a-f]{32}")


def validate_config(config):
    for key in (
        "allowed_uid",
        "allowed_gid",
        "cpu_capacity",
        "game_cpu_capacity",
        "ram_headroom_mib",
        "vram_headroom_mib",
        "gpu_capacity_mib",
        "history_limit",
    ):
        if type(config[key]) is not int or config[key] < 0:
            raise ValueError("Invalid nonnegative integer configuration: " + key)
    if (
        config["allowed_uid"] == 0
        or config["cpu_capacity"] < 1
        or not 1 <= config["game_cpu_capacity"] <= config["cpu_capacity"]
        or config["gpu_capacity_mib"] <= config["vram_headroom_mib"]
        or not 1 <= config["history_limit"] <= 500
    ):
        raise ValueError("Unsafe resource capacity or owner configuration")
    for key, lower, upper in (("poll_seconds", 0.1, 60), ("stability_seconds", 0, 3600)):
        if type(config[key]) not in (int, float) or not lower <= config[key] <= upper:
            raise ValueError("Invalid scheduler timing: " + key)
    for key in ("socket_path", "state_dir", "cgroup_root", "game_marker_path"):
        if not isinstance(config[key], str) or not config[key].startswith("/"):
            raise ValueError("Absolute service path required: " + key)


def size(value):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)(MiB|GiB)", value, re.I)
    if not match:
        raise argparse.ArgumentTypeError("Use MiB or GiB, for example 4GiB")
    result = math.ceil(float(match[1]) * (1024 if match[2].lower() == "gib" else 1))
    if result <= 0:
        raise argparse.ArgumentTypeError("Size must be positive")
    return result


def atomic(path, value):
    path = Path(path)
    temp = path.with_suffix(".new")
    fd = os.open(temp, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def checked(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=15, env=SAFE_ENV, **kwargs).stdout


def clean_label(value):
    if not isinstance(value, str) or not 1 <= len(value.encode("utf-8")) <= 160 or any(ord(c) < 32 for c in value):
        raise ValueError("Supply a safe workload label of 1 to 160 UTF-8 bytes")
    return value


def read_message(stream):
    data = bytearray()
    while b"\n" not in data:
        block = stream.recv(min(65536, MAX_MESSAGE + 1 - len(data)))
        if not block:
            raise ValueError("Incomplete request")
        data.extend(block)
        if len(data) > MAX_MESSAGE:
            raise ValueError("Request exceeds 1 MiB")
    line, tail = data.split(b"\n", 1)
    if tail.strip():
        raise ValueError("One request per connection")
    value = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))
    if not isinstance(value, dict):
        raise ValueError("Request must be an object")
    return value


def rpc(request):
    address = os.environ.get("RESOURCE_SCHEDULER_SOCKET", DEFAULTS["socket_path"])
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(45)
        client.connect(address)
        payload = json.dumps({"version": VERSION, **request}, allow_nan=False).encode() + b"\n"
        if len(payload) > MAX_MESSAGE:
            raise ValueError("Request exceeds 1 MiB")
        client.sendall(payload)
        # Status is bounded by history_limit and may exceed the request size.
        response = bytearray()
        while b"\n" not in response:
            part = client.recv(65536)
            if not part:
                raise RuntimeError("Scheduler disconnected")
            response.extend(part)
            if len(response) > 16 * MAX_MESSAGE:
                raise RuntimeError("Scheduler response exceeds 16 MiB")
    result = json.loads(response)
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "Scheduler request failed"))
    return result["data"]


def pressure(root=Path("/proc/pressure")):
    result = {}
    for name in ("cpu", "memory", "io"):
        try:
            lines = (root / name).read_text().splitlines()
            result[name] = {
                line.split()[0]: {key: float(value) for key, value in (item.split("=") for item in line.split()[1:])}
                for line in lines
            }
        except (OSError, ValueError):
            result[name] = None
    return result


def telemetry():
    result = {"sampled_at": time.time(), "errors": [], "pressure": pressure()}
    try:
        counters = [int(value) for value in Path("/proc/stat").read_text().splitlines()[0].split()[1:9]]
        result["cpu"] = {
            "total_ticks": sum(counters),
            "busy_ticks": sum(counters) - counters[3] - counters[4],
            "logical_cpus": os.cpu_count(),
            "host_actual": None,
        }
        vmstat = dict(line.split() for line in Path("/proc/vmstat").read_text().splitlines())
        result["swap"] = {"pages_in": int(vmstat["pswpin"]), "pages_out": int(vmstat["pswpout"])}
    except (OSError, ValueError, KeyError, IndexError):
        result["cpu"] = {"host_actual": None}
        result["swap"] = {"pages_in": None, "pages_out": None}
    try:
        fields = {
            line.split(":")[0]: int(line.split()[1]) // 1024
            for line in Path("/proc/meminfo").read_text().splitlines()
            if ":" in line
        }
        result["ram"] = {
            "total_mib": fields["MemTotal"],
            "available_mib": fields["MemAvailable"],
            "swap_used_mib": fields["SwapTotal"] - fields["SwapFree"],
        }
    except (OSError, ValueError, KeyError):
        result["ram"] = {"total_mib": None, "available_mib": None, "swap_used_mib": None}
        result["errors"].append("Host memory telemetry unavailable")
    result["gpu"] = dict(
        total_mib=None,
        used_mib=None,
        free_mib=None,
        utilization_percent=None,
        allocations_mib={},
        attribution_confidence="unavailable",
    )
    try:
        row = (
            checked(
                [
                    "nvidia-smi",
                    "--id=0",
                    "--query-gpu=uuid,memory.total,memory.used,utilization.gpu",
                    "--format=csv,noheader,nounits",
                ]
            )
            .strip()
            .split(",")
        )
        gpu, total, used, utilization = (item.strip() for item in row)
        total, used, utilization = int(total), int(used), int(utilization)
        if total <= 0 or not 0 <= used <= total or not 0 <= utilization <= 100:
            raise ValueError("Invalid GPU telemetry")
        result["gpu"].update(total_mib=total, used_mib=used, free_mib=total - used, utilization_percent=utilization)
        # Attribute by kernel cgroup path, not an environment marker clients can forge.
        rows = checked(
            ["nvidia-smi", "--query-compute-apps=gpu_uuid,pid,used_gpu_memory", "--format=csv,noheader,nounits"]
        )
        amounts, seen = {}, set()
        for line in rows.splitlines():
            device, pid, amount = (item.strip() for item in line.split(","))
            if device != gpu or not pid.isdecimal() or not amount.isdecimal() or pid in seen:
                continue
            seen.add(pid)
            try:
                group = Path(f"/proc/{pid}/cgroup").read_text()
            except OSError:
                continue
            match = re.search(r"(?:/|_)job[_-](\d+)(?:/|\b)", group)
            if match:
                amounts[match[1]] = amounts.get(match[1], 0) + int(amount)
        if sum(amounts.values()) > used:
            raise ValueError("GPU attribution exceeds device usage")
        result["gpu"].update(allocations_mib=amounts, attribution_confidence="cgroup-compute-processes")
    except (OSError, ValueError, subprocess.SubprocessError):
        result["errors"].append("GPU telemetry or process attribution unavailable")
    # Cgroup v2 high-water marks are authoritative where available; missing stays null.
    result["cgroups"] = {}
    try:
        for path in Path("/sys/fs/cgroup").glob("system.slice/*slurmstepd.scope/job_*"):
            match = re.fullmatch(r"job_(\d+)", path.name)
            if not match:
                continue
            metrics = {}
            try:
                metrics["cpu_set"] = (path / "cpuset.cpus.effective").read_text().strip()
            except OSError:
                metrics["cpu_set"] = None
            for field in ("memory.current", "memory.peak"):
                try:
                    metrics[field] = int((path / field).read_text()) / 1048576
                except (OSError, ValueError):
                    metrics[field] = None
            try:
                metrics["cpu_usec"] = int(
                    dict(line.split() for line in (path / "cpu.stat").read_text().splitlines())["usage_usec"]
                )
                metrics["oom_kill"] = int(
                    dict(line.split() for line in (path / "memory.events").read_text().splitlines())["oom_kill"]
                )
            except (OSError, ValueError, KeyError):
                metrics.update(cpu_usec=None, oom_kill=None)
            result["cgroups"][match[1]] = metrics
    except OSError:
        pass
    return result


def admission_reason(job, jobs, snapshot, config):
    """Fail closed; unknown managed actual gets no credit against reservations."""
    running = [item for item in jobs if item["state"] in ACTIVE]
    request = job["requested"]
    if any(item["state"] == "unknown" for item in running):
        return "Slurm state unknown; retaining reservations until reconciled"
    # Do not release another job before Slurm has accounted for the previous grant.
    if any(item["state"] == "pending" for item in running):
        return "Waiting for Slurm to start the previous allocation"
    game_active = any(item["priority"] == "game" and item["state"] not in TERMINAL for item in jobs)
    game_active = game_active or snapshot.get("game_active", False)
    capacity = config["game_cpu_capacity"] if game_active and job.get("priority") != "game" else config["cpu_capacity"]
    if (
        sum(item["requested"]["cpu"] for item in running if item["priority"] != "game" or job.get("priority") == "game")
        + request["cpu"]
        > capacity
    ):
        return "CPU reservation capacity exhausted"
    available = snapshot["ram"]["available_mib"]
    if available is None:
        return "Host memory telemetry unavailable"
    outstanding = sum(max(0, item["requested"]["ram_mib"] - (item["observed"].get("ram_mib") or 0)) for item in running)
    if available - config["ram_headroom_mib"] - outstanding < request["ram_mib"]:
        return "Insufficient RAM after unused reservations and desktop headroom"
    if not request["vram_mib"]:
        return None
    if snapshot.get("game_active"):
        return "External GameMode is active; waiting for exclusive GPU access"
    gpu_jobs = [item for item in running if item["requested"]["vram_mib"]]
    if any(item["mode"] == "exclusive" for item in gpu_jobs):
        return "Exclusive GPU workload remains active"
    if job["mode"] == "exclusive" and gpu_jobs:
        return "Waiting for shared GPU workloads to finish and unload"
    gpu = snapshot["gpu"]
    if gpu["free_mib"] is None:
        return "GPU telemetry unavailable"
    outstanding = sum(
        max(0, item["requested"]["vram_mib"] - (item["observed"].get("vram_mib") or 0)) for item in gpu_jobs
    )
    # Exclusive reserves the cooperative pool but external desktop use can fluctuate.
    needed = request["vram_mib"]
    if job.get("vram_auto") and job["mode"] == "exclusive":
        needed = max(1, min(config["gpu_capacity_mib"], gpu["free_mib"]) - config["vram_headroom_mib"])
    if gpu["free_mib"] - config["vram_headroom_mib"] - outstanding < needed:
        return "Insufficient VRAM after unused reservations and desktop headroom"
    return None


class Slurm:
    def __init__(self, config):
        self.config = config

    def submit(self, job, directory):
        req = job["requested"]
        argv = [
            "sbatch",
            "--parsable",
            "--hold",
            "--uid=0",
            "--gid=0",
            "--ntasks=1",
            "--nodes=1",
            "--no-requeue",
            "--export=NONE",
            f"--partition={self.config['partition']}",
            f"--job-name=rs-{job['id']}",
            f"--comment=resource:{job['id']}",
            f"--cpus-per-task={req['cpu']}",
            f"--mem={req['ram_mib']}M",
            f"--output={directory}/stdout",
            f"--error={directory}/stderr",
        ]
        if req["vram_mib"]:
            argv.append("--gres=gpu:1" if job["mode"] == "exclusive" else f"--gres=shard:{req['vram_mib']}")
        script = (
            "#!/bin/sh\nexec "
            + shlex.join([sys.executable, "-I", str(Path(__file__).resolve()), "step", str(directory)])
            + "\n"
        )
        job_id = checked(argv, input=script).strip().split(";")[0]
        if not job_id.isdecimal():
            raise RuntimeError("Invalid Slurm submission identity")
        return job_id

    def jobs(self):
        # JSON fields are read from Slurm itself; no reservation reconstruction from journal.
        return json.loads(checked(["squeue", "--json"]))["jobs"]

    def detail(self, job_id):
        return json.loads(checked(["scontrol", "show", "job", "--json", job_id]))["jobs"][0]

    def release(self, job_id):
        checked(["scontrol", "release", job_id])

    def cancel(self, job_id):
        # TERM then Slurm's configured KillWait/KILL; cgroup cleanup remains Slurm-owned.
        checked(["scancel", job_id])


def slurm_state(row):
    state = row.get("job_state", "UNKNOWN")
    if isinstance(state, list):
        state = state[0] if state else "UNKNOWN"
    return {
        "PENDING": "pending",
        "RUNNING": "running",
        "CONFIGURING": "pending",
        "COMPLETING": "running",
        "COMPLETED": "completed",
        "CANCELLED": "cancelled",
        "FAILED": "failed",
        "TIMEOUT": "failed",
        "OUT_OF_MEMORY": "failed",
        "NODE_FAIL": "failed",
        "BOOT_FAIL": "failed",
        "PREEMPTED": "failed",
    }.get(state, "unknown")


def slurm_exit(value):
    def scalar(item):
        for _ in range(5):
            if type(item) is int:
                return item
            if not isinstance(item, dict) or item.get("set") is False:
                return None
            item = next((item[k] for k in ("number", "id", "value") if k in item), None)
        return None

    if not isinstance(value, dict):
        return None
    signal_number = scalar(value.get("signal"))
    return 128 + signal_number if signal_number else scalar(value.get("return_code"))


class Backend:
    def __init__(self, config, slurm=None, sample=telemetry):
        self.config = {**DEFAULTS, **config}
        validate_config(self.config)
        self.directory = Path(self.config["state_dir"])
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        self.lock_fd = os.open(self.directory / "daemon.lock", os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.state_path = self.directory / "state.json"
        self.state = (
            json.loads(self.state_path.read_text())
            if self.state_path.exists()
            else {"revision": 0, "paused": False, "jobs": []}
        )
        self.slurm = slurm or Slurm(self.config)
        self.sample = sample
        self.snapshot = None
        self.errors = []
        self.healthy_since = None
        self.last_sample_event = 0
        self.game_protection_errors = []
        self.game_active = False
        self.previous_cpu = None
        self.save()

    def save(self):
        self.state["revision"] += 1
        atomic(self.state_path, self.state)

    def event(self, job, event, **fields):
        # Fixed fields and explicit safe metadata only. Never argv, environment or output.
        value = dict(
            schema_version=1,
            policy_version=str(self.config["policy_version"]),
            timestamp=time.time(),
            event=event,
            job_id=job.get("id"),
            label=job.get("label"),
            agent=job.get("agent"),
            worktree=job.get("worktree"),
            category=job.get("category"),
            slurm_job_id=job.get("slurm_job_id"),
            requested=({**job["requested"], "vram_mib": None} if job.get("vram_auto") else job.get("requested")),
            vram_estimate="all-available" if job.get("vram_auto") else "declared-peak",
            allocation=job.get("requested") if job.get("released") else None,
            **fields,
        )
        if job.get("id"):
            job.setdefault("events", []).append(value)
            job["events"] = job["events"][-64:]
        message = json.dumps(value, allow_nan=False, separators=(",", ":"))
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as journal:
                journal.sendto(
                    (
                        "MESSAGE=" + message + "\nSYSLOG_IDENTIFIER=resource-scheduler\n"
                        "RESOURCE_EVENT="
                        + event
                        + "\nRESOURCE_JOB_ID="
                        + (job.get("id") or "host")
                        + "\nRESOURCE_POLICY_VERSION="
                        + str(self.config["policy_version"])
                    ).encode(),
                    "/run/systemd/journal/socket",
                )
        except OSError:
            # systemd captures stdout on minimal systems without the native socket.
            print(message, flush=True)

    def changed(self, job, state=None, reason=None):
        if state is not None:
            job["state"] = state
        if reason is not None:
            job["wait_reason"] = reason
        job["revision"] += 1
        self.save()

    def submit(self, request, uid):
        if request.get("nested"):
            raise ValueError("Nested reservations are forbidden; run within the existing budget")
        if sum(j["state"] not in TERMINAL for j in self.state["jobs"]) >= 256:
            raise ValueError("Queue limit reached; wait for existing jobs")
        req = request["requested"]
        if not isinstance(req, dict):
            raise ValueError("Resource budgets must be an object")
        for name in ("cpu", "ram_mib", "vram_mib"):
            if type(req.get(name)) is not int or req[name] < (0 if name == "vram_mib" else 1):
                raise ValueError("Invalid resource budget")
        req = {key: req[key] for key in ("cpu", "ram_mib", "vram_mib")}
        if req["cpu"] > self.config["cpu_capacity"]:
            raise ValueError("CPU request exceeds configured background capacity")
        mode = request.get("mode", "shared")
        if mode not in ("shared", "exclusive"):
            raise ValueError("Invalid sharing mode")
        vram_auto = mode == "exclusive" and req["vram_mib"] == 0
        if vram_auto:
            # Fixed usable maximum; current free memory is never promoted to pool size.
            req["vram_mib"] = self.config["gpu_capacity_mib"] - self.config["vram_headroom_mib"]
        if req["vram_mib"] > self.config["gpu_capacity_mib"] - self.config["vram_headroom_mib"]:
            raise ValueError("VRAM request exceeds configured usable capacity")
        if request.get("priority") not in ("background", "interactive", "game"):
            raise ValueError("Invalid priority")
        if request["priority"] == "game" and mode != "exclusive":
            raise ValueError("Game requests require exclusive GPU access")
        category = request.get("category", "other")
        if category not in ("build", "inference", "render", "game", "other"):
            raise ValueError("Invalid workload category")
        payload = request["payload"]
        if (
            not isinstance(payload, dict)
            or not isinstance(payload.get("command"), list)
            or not payload["command"]
            or any(not isinstance(v, str) or "\0" in v for v in payload["command"])
            or not isinstance(payload.get("env"), dict)
            or any(
                not isinstance(k, str) or not isinstance(v, str) or "=" in k or "\0" in k + v
                for k, v in payload["env"].items()
            )
            or not isinstance(payload.get("cwd"), str)
            or not payload["cwd"].startswith("/")
        ):
            raise ValueError("Invalid private execution payload")
        origin = request.get("origin", "host")
        if origin != "host" and not re.fullmatch(r"agent-sandbox-[A-Za-z0-9_.-]{1,128}", origin):
            raise ValueError("Invalid sandbox identity")
        job_id = uuid.uuid4().hex
        job = dict(
            id=job_id,
            revision=1,
            label=clean_label(request["label"]),
            owner_uid=uid,
            agent=clean_label(request.get("agent") or "unknown"),
            worktree=clean_label(request.get("worktree") or "unknown"),
            project=clean_label(request.get("project") or "unknown"),
            origin=origin,
            category=category,
            priority=request["priority"],
            mode=mode,
            vram_auto=vram_auto,
            state="queued",
            created_at=time.time(),
            started_at=None,
            ended_at=None,
            slurm_job_id=None,
            requested=dict(req),
            observed=dict(
                cpu_percent=None,
                cpu_usec=None,
                ram_mib=None,
                ram_peak_mib=None,
                vram_mib=None,
                vram_peak_mib=None,
                gpu_utilization_percent=None,
                attribution_confidence="unavailable",
                oom_kill=None,
            ),
            wait_reason="Submitting held Slurm allocation",
            exit_code=None,
            cleanup="pending",
            model=None,
            events=[],
        )
        directory = self.directory / job_id
        directory.mkdir(mode=0o700)
        atomic(
            directory / "payload.json",
            {
                **payload,
                "id": job_id,
                "origin": origin,
                "uid": uid,
                "gid": self.config["allowed_gid"],
                "budget": dict(req),
                "stdout": str(directory / "stdout"),
                "stderr": str(directory / "stderr"),
            },
        )
        self.state["jobs"].append(job)
        self.save()  # Persist UUID before submitting; interrupted submission is reconciled by name.
        self.event(job, "submission")
        try:
            job["slurm_job_id"] = self.slurm.submit(job, directory)
            job["wait_reason"] = "Awaiting headroom policy"
            self.save()
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            # A nonzero sbatch reply is reconciled against the held queue before
            # classifying rejection. A timeout/lost reply remains uncertain.
            job["submission_rejected"] = isinstance(error, subprocess.CalledProcessError)
            self.changed(job, "unknown", "Submission outcome unknown; reconciling Slurm identity")
            raise RuntimeError("Slurm submission outcome unknown; inspect status before resubmitting") from None
        return {"id": job_id, "revision": job["revision"]}

    def tick(self):
        self.errors = []
        self.snapshot = self.sample()
        current_cpu = self.snapshot.get("cpu", {})
        previous_cpu = self.previous_cpu
        if (
            previous_cpu
            and current_cpu.get("total_ticks", 0) > previous_cpu.get("total_ticks", 0)
            and current_cpu.get("busy_ticks", -1) >= previous_cpu.get("busy_ticks", 0)
        ):
            current_cpu["host_actual"] = (
                (current_cpu["busy_ticks"] - previous_cpu["busy_ticks"])
                / (current_cpu["total_ticks"] - previous_cpu["total_ticks"])
                * current_cpu["logical_cpus"]
            )
        self.previous_cpu = dict(current_cpu)
        self.snapshot["game_active"] = Path(self.config["game_marker_path"]).exists()
        now = time.time()
        try:
            rows = self.slurm.jobs()
            by_id = {str(row["job_id"]): row for row in rows}
            by_name = {row.get("name"): row for row in rows}
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            self.errors.append("Slurm unavailable; admissions stopped")
            self.healthy_since = None
            return
        for job in self.state["jobs"]:
            if job["state"] in TERMINAL:
                continue
            if not job["slurm_job_id"]:
                row = by_name.get("rs-" + job["id"])
                if row:
                    job["slurm_job_id"] = str(row["job_id"])
                    self.event(job, "recovery", reason="Recovered immutable UUID from Slurm name")
                else:
                    if job.get("submission_rejected"):
                        job.update(
                            state="failed",
                            exit_code=1,
                            ended_at=now,
                            cleanup="slurm-rejected-no-allocation",
                            wait_reason=None,
                            revision=job["revision"] + 1,
                        )
                        (self.directory / job["id"] / "payload.json").unlink(missing_ok=True)
                        self.event(
                            job,
                            "completion",
                            exit_code=1,
                            cleanup=job["cleanup"],
                            queue_seconds=now - job["created_at"],
                            execution_seconds=0,
                        )
                    else:
                        self.changed(job, "unknown", "Submission identity unknown; operator reconciliation required")
                    continue
            row = by_id.get(job["slurm_job_id"])
            if row is None:
                try:
                    row = self.slurm.detail(job["slurm_job_id"])
                except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
                    self.changed(job, "unknown", "Slurm allocation missing; cleanup not proven")
                    continue
            if row.get("name") != "rs-" + job["id"]:
                self.changed(job, "unknown", "Slurm ID identity mismatch; refusing reused allocation")
                continue
            state = slurm_state(row)
            if state == "pending" and not job.get("released", False):
                state = "queued"
            if state != job["state"]:
                job["state"] = state
                job["revision"] += 1
                if state == "running":
                    job["started_at"] = job["started_at"] or now
                    job["wait_reason"] = None
                    self.event(job, "start", queue_seconds=now - job["created_at"])
                elif state in TERMINAL:
                    job["ended_at"] = now
                    exit_value = row.get("exit_code") or {}
                    job["exit_code"] = slurm_exit(exit_value)
                    # A terminal Slurm state (not mere PID absence) proves its cgroup cleanup.
                    job["cleanup"] = "slurm-terminal"
                    result_path = self.directory / job["id"] / "result.json"
                    if result_path.exists():
                        summary = json.loads(result_path.read_text())
                        job["exit_code"] = summary["exit_code"]
                        for key, value in summary.get("observed", {}).items():
                            if value is not None:
                                job["observed"][key] = value
                    job["wait_reason"] = None
                    self.event(
                        job,
                        "completion",
                        exit_code=job["exit_code"],
                        cleanup=job["cleanup"],
                        observed=job["observed"],
                        queue_seconds=(job["started_at"] or now) - job["created_at"],
                        execution_seconds=now - job["started_at"] if job["started_at"] else 0,
                    )
                    # Secrets are only retained while execution/recovery may require them.
                    (self.directory / job["id"] / "payload.json").unlink(missing_ok=True)
            if state in ACTIVE:
                metrics = self.snapshot.get("cgroups", {}).get(job["slurm_job_id"], {})
                observed = job["observed"]
                observed["ram_mib"] = metrics.get("memory.current")
                if metrics.get("memory.peak") is not None:
                    observed["ram_peak_mib"] = max(observed["ram_peak_mib"] or 0, metrics["memory.peak"])
                previous_cpu = observed.get("cpu_usec")
                previous_at = observed.get("sampled_at")
                current_cpu = metrics.get("cpu_usec")
                observed["cpu_percent"] = (
                    (current_cpu - previous_cpu) / ((now - previous_at) * 10000)
                    if current_cpu is not None and previous_cpu is not None and previous_at and now > previous_at
                    else None
                )
                observed["cpu_usec"] = current_cpu
                observed["sampled_at"] = now
                observed["oom_kill"] = metrics.get("oom_kill")
                observed["cpu_set"] = metrics.get("cpu_set")
                amount = self.snapshot["gpu"].get("allocations_mib", {}).get(job["slurm_job_id"])
                observed["vram_mib"] = amount
                if amount is not None:
                    observed["vram_peak_mib"] = max(observed["vram_peak_mib"] or 0, amount)
                    observed["attribution_confidence"] = "cgroup-compute-processes"
        self.apply_game_protection()
        memory = self.snapshot["pressure"].get("memory")
        pressure_hold = bool(memory and memory.get("full", {}).get("avg10", 0) >= 1)
        low_ram = (
            self.snapshot["ram"]["available_mib"] is None
            or self.snapshot["ram"]["available_mib"] < self.config["ram_headroom_mib"]
        )
        if pressure_hold or low_ram:
            if self.healthy_since is not None:
                self.event({}, "pressure_intervention", action="hold-new-admissions")
            self.healthy_since = None
        elif self.healthy_since is None:
            self.healthy_since = now
        queued = sorted(
            (job for job in self.state["jobs"] if job["state"] == "queued"),
            key=lambda j: (
                0 if j["priority"] == "game" else 1,
                0 if now - j["created_at"] >= 60 else 1,
                0 if now - j["created_at"] >= 60 or j["priority"] == "interactive" else 1,
                j["created_at"],
                j["id"],
            ),
        )
        for index, job in enumerate(queued):
            if self.game_protection_errors:
                reason = "Game CPU protection unavailable; new admissions stopped"
            elif self.state["paused"]:
                reason = "New admissions paused by owner"
            elif self.healthy_since is None or now - self.healthy_since < self.config["stability_seconds"]:
                reason = "Pressure hold; waiting for stable desktop headroom"
            elif index:
                reason = "Behind earlier job " + queued[0]["id"]
            else:
                reason = admission_reason(job, self.state["jobs"], self.snapshot, self.config)
            if reason != job["wait_reason"]:
                self.changed(job, reason=reason or "Slurm allocation released")
                if reason:
                    self.event(job, "waiting", reason=reason, snapshot=self.public_telemetry())
            if reason is None:
                try:
                    if job.get("vram_auto"):
                        job["requested"]["vram_mib"] = (
                            min(self.config["gpu_capacity_mib"], self.snapshot["gpu"]["free_mib"])
                            - self.config["vram_headroom_mib"]
                        )
                        payload_path = self.directory / job["id"] / "payload.json"
                        payload = json.loads(payload_path.read_text())
                        payload["budget"] = dict(job["requested"])
                        atomic(payload_path, payload)
                        self.save()
                    self.slurm.release(job["slurm_job_id"])
                    job["released"] = True
                    self.changed(job, "pending", "Waiting for Slurm allocation")
                    self.event(job, "admission", snapshot=self.public_telemetry())
                except (OSError, subprocess.SubprocessError):
                    self.errors.append("Slurm release failed; reconciliation required")
                break
        if now - self.last_sample_event >= 30 and any(j["state"] in ACTIVE for j in self.state["jobs"]):
            self.event({}, "sample", snapshot=self.public_telemetry())
            self.last_sample_event = now
        terminal = [j for j in self.state["jobs"] if j["state"] in TERMINAL]
        keep = {j["id"] for j in terminal[-self.config["history_limit"] :]}
        for job in terminal:
            if job["id"] not in keep:
                directory = self.directory / job["id"]
                for name in ("stdout", "stderr", "result.json", "payload.json"):
                    (directory / name).unlink(missing_ok=True)
                directory.rmdir()
        self.state["jobs"] = [j for j in self.state["jobs"] if j["state"] not in TERMINAL or j["id"] in keep]
        self.save()

    def apply_game_protection(self):
        self.game_active = bool(self.snapshot.get("game_active")) or any(
            j["priority"] == "game" and j["state"] not in TERMINAL for j in self.state["jobs"]
        )
        previous_errors = self.game_protection_errors
        self.game_protection_errors = []
        running = [j for j in self.state["jobs"] if j["state"] == "running" and j["priority"] != "game"]
        total = sum(j["requested"]["cpu"] for j in running)
        for job in running:
            paths = list(
                Path(self.config["cgroup_root"]).glob("system.slice/*slurmstepd.scope/job_" + job["slurm_job_id"])
            )
            if not paths:
                if self.game_active:
                    self.game_protection_errors.append("Slurm CPU cgroup unavailable for " + job["id"])
                continue
            try:
                for path in paths:
                    quota = (
                        f"{max(1000, int(100000 * self.config['game_cpu_capacity'] * job['requested']['cpu'] / total))} 100000"
                        if self.game_active and total > self.config["game_cpu_capacity"]
                        else "max 100000"
                    )
                    for name, value in (("cpu.max", quota), ("cpu.weight", "25" if self.game_active else "100")):
                        field = path / name
                        if not field.exists():
                            raise OSError("CPU controller unavailable")
                        if field.read_text().strip() != value:
                            field.write_text(value + "\n")
            except OSError:
                self.game_protection_errors.append("Slurm CPU protection could not be applied to " + job["id"])
        if self.game_protection_errors != previous_errors:
            self.event({}, "game_cpu_protection", errors=self.game_protection_errors, active=self.game_active)

    @staticmethod
    def public_job(job):
        result = {
            **job,
            "requested": dict(job["requested"]),
            "events": [{k: v for k, v in event.items() if k != "snapshot"} for event in job["events"][-8:]],
        }
        effective = job["requested"]["vram_mib"] if job.get("released") or job["state"] == "running" else None
        result["allocation"] = {
            "cpu": job["requested"]["cpu"],
            "ram_mib": job["requested"]["ram_mib"],
            "vram_mib": effective,
        }
        result["vram_estimate"] = "all-available" if job.get("vram_auto") else "declared-peak"
        if job.get("vram_auto"):
            result["requested"]["vram_mib"] = None
            for event in result["events"]:
                if event.get("requested"):
                    event["requested"] = {**event["requested"], "vram_mib": None}
        return result

    def public_telemetry(self):
        snapshot = self.snapshot or {
            "ram": {},
            "gpu": {},
            "pressure": {},
            "errors": ["Not sampled"],
            "sampled_at": None,
        }
        running = [j for j in self.state["jobs"] if j["state"] in ACTIVE]
        ram_actual = [j["observed"]["ram_mib"] for j in running]
        gpu_actual = [j["observed"]["vram_mib"] for j in running if j["requested"]["vram_mib"]]
        cpu_samples = [j["observed"]["cpu_percent"] for j in running]
        cpu_actual = sum(cpu_samples) / 100 if all(v is not None for v in cpu_samples) else None
        host_actual = snapshot.get("cpu", {}).get("host_actual")
        gpu_managed = sum(gpu_actual) if all(v is not None for v in gpu_actual) else None
        gpu_used = snapshot["gpu"].get("used_mib")
        return dict(
            sampled_at=snapshot["sampled_at"],
            errors=snapshot["errors"],
            pressure=snapshot["pressure"],
            swap=snapshot.get("swap", {"pages_in": None, "pages_out": None}),
            cpu=dict(
                capacity=self.config["cpu_capacity"],
                reserved=sum(j["requested"]["cpu"] for j in running),
                actual=cpu_actual,
                external=max(0, host_actual - cpu_actual)
                if host_actual is not None and cpu_actual is not None
                else None,
                host_actual=host_actual,
                logical_cpus=snapshot.get("cpu", {}).get("logical_cpus"),
                attribution_confidence="sampled-kernel-counters" if cpu_actual is not None else "unavailable",
                unit="Slurm CPU",
                effective_background_capacity=self.config["game_cpu_capacity"]
                if self.game_active
                else self.config["cpu_capacity"],
                game_active=self.game_active,
                game_protection_errors=self.game_protection_errors,
            ),
            ram={
                **snapshot["ram"],
                "headroom_mib": self.config["ram_headroom_mib"],
                "reserved_mib": sum(j["requested"]["ram_mib"] for j in running),
                "managed_actual_mib": sum(ram_actual) if all(v is not None for v in ram_actual) else None,
            },
            gpu={
                k: v
                for k, v in {
                    **snapshot["gpu"],
                    "headroom_mib": self.config["vram_headroom_mib"],
                    "reserved_mib": sum(j["requested"]["vram_mib"] for j in running),
                    "managed_actual_mib": gpu_managed,
                    "external_mib": max(0, gpu_used - gpu_managed)
                    if gpu_used is not None and gpu_managed is not None
                    else None,
                }.items()
                if k != "allocations_mib"
            },
        )

    def status(self):
        jobs = self.state["jobs"]
        mode = "manual_hold" if self.state["paused"] else "normal"
        if mode == "normal" and (
            self.healthy_since is None or time.time() - self.healthy_since < self.config["stability_seconds"]
        ):
            mode = "pressure_hold"
        if mode == "normal":
            for state, suffix in (("running", "running"), ("pending", "pending"), ("queued", "pending")):
                matching = [j for j in jobs if j["state"] == state and j["mode"] == "exclusive"]
                if matching:
                    mode = ("game_" if any(j["priority"] == "game" for j in matching) else "exclusive_") + suffix
                    break
            if mode == "normal" and self.game_active:
                mode = "game_running"
        value = dict(
            schema_version=1,
            policy_version=str(self.config["policy_version"]),
            revision=self.state["revision"],
            generated_at=time.time(),
            connected=True,
            mode=mode,
            capabilities=dict(
                cancel=True, terminate=True, pause=True, resume=True, priority=False, unload=False, model_reports=True
            ),
            telemetry=self.public_telemetry(),
            jobs=[self.public_job(j) for j in jobs if j["state"] not in TERMINAL],
            history=[self.public_job(j) for j in reversed(jobs) if j["state"] in TERMINAL],
            errors=self.errors,
        )
        value["truncated"] = {"history": 0, "events": False}
        # Preserve ALL active jobs; compact events before shedding oldest history.
        if len(json.dumps(value, ensure_ascii=False).encode()) > 900000:
            for job in value["jobs"] + value["history"]:
                job["events"] = []
            value["truncated"]["events"] = True
        while len(json.dumps(value, ensure_ascii=False).encode()) > 900000 and value["history"]:
            value["history"].pop()
            value["truncated"]["history"] += 1
        return value

    def handle(self, request, uid):
        if uid != self.config["allowed_uid"]:
            raise PermissionError("Peer UID is not authorized")
        if request.get("version") != VERSION:
            raise ValueError("Unsupported API version")
        action = request.get("action")
        if action == "status":
            return self.status()
        if action == "submit":
            return self.submit(request, uid)
        if action in ("pause", "resume"):
            if request.get("confirm") is not True:
                raise ValueError("Explicit confirmation required")
            self.state["paused"] = action == "pause"
            self.event({}, "admissions_" + action)
            self.save()
            return {"revision": self.state["revision"], "paused": self.state["paused"]}
        job_id = request.get("id", "")
        if not isinstance(job_id, str) or not ID_RE.fullmatch(job_id):
            raise ValueError("Full immutable job ID required")
        job = next((j for j in self.state["jobs"] if j["id"] == job_id), None)
        if job is None or job["owner_uid"] != uid:
            raise PermissionError("Job is unavailable to this owner")
        if action == "model-event":
            if job["state"] != "running":
                raise ValueError("Model events require a running reservation")
            state = request.get("state")
            if state not in ("loading", "ready", "busy", "idle", "unloaded"):
                raise ValueError("Invalid model lifecycle event")
            label = clean_label(request["model_label"])
            now = time.time()
            model = job.get("model") or {}
            if state == "loading":
                model = dict(
                    label=label,
                    state=state,
                    load_started_at=now,
                    loaded_at=None,
                    load_seconds=None,
                    unloaded_at=None,
                    attribution_confidence="owner-reported",
                )
            elif model.get("label") != label:
                raise ValueError("Model label does not match loading event")
            if state == "ready":
                if model.get("load_started_at") is None:
                    raise ValueError("Loading event required before ready")
                model["loaded_at"] = now
                model["load_seconds"] = now - model["load_started_at"]
            if state == "unloaded":
                model["unloaded_at"] = now
            model["state"] = state
            job["model"] = model
            self.event(job, "model_" + state, model=model)
            self.changed(job)
            return {"id": job_id, "revision": job["revision"], "model": model}
        if action == "output":
            result = {}
            for name in ("stdout", "stderr"):
                offset = request.get(name + "_offset", 0)
                if type(offset) is not int or offset < 0:
                    raise ValueError("Invalid output offset")
                try:
                    with (self.directory / job_id / name).open("rb") as stream:
                        stream.seek(offset)
                        data = stream.read(32768)
                    result[name] = data.decode(errors="replace")
                    result[name + "_offset"] = offset + len(data)
                except FileNotFoundError:
                    result[name], result[name + "_offset"] = "", offset
            result["job"] = job
            return result
        if action not in ("cancel", "terminate"):
            raise ValueError("Unsupported control action")
        if request.get("confirm") is not True or request.get("revision") != job["revision"]:
            raise ValueError("Confirmation and current job revision required")
        if job["state"] in TERMINAL:
            raise ValueError("Job already finished")
        if action == "cancel" and job["state"] not in ("queued", "pending"):
            raise ValueError("Running work requires terminate")
        if not job["slurm_job_id"]:
            raise ValueError("Unknown Slurm identity; cannot cancel safely")
        current = self.slurm.detail(job["slurm_job_id"])
        if current.get("name") != "rs-" + job["id"]:
            raise ValueError("Slurm allocation identity changed; refusing control")
        self.slurm.cancel(job["slurm_job_id"])
        self.event(job, "cancellation", action=action)
        job["cleanup"] = "cancellation-requested"
        self.changed(job)
        return {"id": job_id, "revision": job["revision"], "pending": True}


def legacy_guard(uid):
    """Drain gate: a held legacy record is live even when its process is idle."""
    directory = Path(f"/run/user/{uid}/gpu-scheduler")
    if not directory.exists():
        return
    try:
        mutex_fd = os.open(directory / "admission.lock", os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        if any(directory.glob("*.json")):
            raise RuntimeError("Legacy lease records exist without their admission lock") from None
        return
    with os.fdopen(mutex_fd) as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        for path in directory.glob("*.json"):
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise RuntimeError(
                        "Legacy GPU reservation remains active; drain old queue before cutover"
                    ) from None


def daemon(config_path):
    if os.getuid() != 0:
        raise RuntimeError("The admission service requires the trusted host root service")
    config = {**DEFAULTS, **json.loads(Path(config_path).read_text())}
    legacy_guard(config["allowed_uid"])
    backend = Backend(config)
    path = Path(config["socket_path"])
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        os.chown(path, config["allowed_uid"], config["allowed_gid"])
        os.chmod(path, 0o600)
        listener.listen(32)
        next_tick = 0
        while True:
            if time.monotonic() >= next_tick:
                try:
                    backend.tick()
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    backend.errors = ["Reconciliation failed; admissions stopped"]
                    backend.healthy_since = None
                next_tick = time.monotonic() + config["poll_seconds"]
            ready, _, _ = select.select([listener], [], [], max(0, next_tick - time.monotonic()))
            if not ready:
                continue
            client, _ = listener.accept()
            with client:
                client.settimeout(3)
                try:
                    _, uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                    # Authenticate before parsing potentially large input.
                    if uid != config["allowed_uid"]:
                        raise PermissionError("Peer UID is not authorized")
                    data = backend.handle(read_message(client), uid)
                    result = {"ok": True, "data": data}
                except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
                    # Exception details may include executable paths/arguments: never return them.
                    result = {
                        "ok": False,
                        "error": "Request rejected, stale revision, or Slurm unavailable; inspect resource-status",
                    }
                try:
                    client.sendall(json.dumps(result, allow_nan=False, ensure_ascii=False).encode() + b"\n")
                except OSError:
                    pass


def namespace_command(payload, payload_fd):
    """Resolve Docker's init once, pin handles, never join the container cgroup."""
    origin = payload["origin"]
    if not re.fullmatch(r"agent-sandbox-[A-Za-z0-9_.-]{1,128}", origin):
        raise ValueError("Untrusted sandbox identity")
    value = json.loads(checked(["docker", "inspect", "--type=container", origin]))[0]
    if (
        value.get("Name") != "/" + origin
        or not value["State"].get("Running")
        or value["Config"].get("User") != f"{payload['uid']}:{payload['gid']}"
        or not any(
            m.get("Destination") == "/nix/store" and m.get("Source") == "/nix/store" and m.get("RW") is False
            for m in value.get("Mounts", [])
        )
    ):
        raise ValueError("Sandbox identity or immutable runtime mount mismatch")
    pid = value["State"]["Pid"]
    if type(pid) is not int or pid < 2:
        raise ValueError("Invalid sandbox init PID")
    handles = []
    try:
        proc = Path(f"/proc/{pid}")
        start = (proc / "stat").read_text().rsplit(")", 1)[1].split()[19]
        root_fd = os.open(proc / "root", os.O_PATH)
        handles.append(root_fd)
        for executable in (sys.executable, str(Path(__file__).resolve())):
            host_stat = os.stat(executable)
            target_stat = os.stat(f"/proc/self/fd/{root_fd}" + executable)
            if (host_stat.st_dev, host_stat.st_ino) != (target_stat.st_dev, target_stat.st_ino):
                raise ValueError("Sandbox runtime differs from trusted host store")
            if not executable.startswith("/nix/store/"):
                raise ValueError("Namespace bootstrap requires immutable Nix store runtime")
        argv = ["nsenter"]
        for name, option in (("mnt", "mount"), ("net", "net"), ("ipc", "ipc"), ("uts", "uts"), ("pid", "pid")):
            fd = os.open(proc / "ns" / name, os.O_RDONLY)
            handles.append(fd)
            argv.append(f"--{option}=/proc/self/fd/{fd}")
        if (proc / "stat").read_text().rsplit(")", 1)[1].split()[19] != start:
            raise ValueError("Sandbox init changed during namespace capture")
        argv += [
            f"--root=/proc/self/fd/{root_fd}",
            "--wd=/",
            "--",
            sys.executable,
            "-I",
            str(Path(__file__).resolve()),
            "step-exec",
            str(payload_fd),
        ]
        return argv, handles
    except BaseException:
        for fd in handles:
            os.close(fd)
        raise


def step(directory):
    # Slurm executes this fixed root-owned/store bootstrap. Caller env is private data.
    if os.getuid() != 0 or not os.environ.get("SLURM_JOB_ID"):
        raise RuntimeError("Step bootstrap must be launched by root Slurm")
    directory = Path(directory)
    payload_fd = os.open(directory / "payload.json", os.O_RDONLY | os.O_NOFOLLOW)
    handles = []
    try:
        with os.fdopen(os.dup(payload_fd)) as stream:
            payload = json.load(stream)
        if payload["id"] != directory.name or not ID_RE.fullmatch(directory.name):
            raise ValueError("Private payload identity mismatch")
        os.lseek(payload_fd, 0, os.SEEK_SET)
        argv = [sys.executable, "-I", str(Path(__file__).resolve()), "step-exec", str(payload_fd)]
        if payload["origin"] != "host":
            argv, handles = namespace_command(payload, payload_fd)
        # Files are root-owned and private. Bound stored stdout/stderr independently.
        streams = {name: (directory / name).open("wb") for name in ("stdout", "stderr")}
        child = subprocess.Popen(
            argv, pass_fds=(payload_fd, *handles), env=SAFE_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        pipes = {child.stdout: streams["stdout"], child.stderr: streams["stderr"]}
        totals = {stream: 0 for stream in streams.values()}
        while pipes:
            ready, _, _ = select.select(list(pipes), [], [], 1)
            for pipe in ready:
                chunk = os.read(pipe.fileno(), 32768)
                if not chunk:
                    pipe.close()
                    del pipes[pipe]
                    continue
                stream = pipes[pipe]
                remaining = max(0, 8 * MAX_MESSAGE - totals[stream])
                stream.write(chunk[:remaining])
                stream.flush()
                totals[stream] += len(chunk[:remaining])
        code = child.wait()
        for stream in streams.values():
            stream.close()
        observed = {}
        try:
            cgroup = Path("/sys/fs/cgroup") / Path("/proc/self/cgroup").read_text().split("::", 1)[1].strip().lstrip(
                "/"
            )
            observed["ram_peak_mib"] = int((cgroup / "memory.peak").read_text()) / 1048576
            observed["cpu_usec"] = int(
                dict(line.split() for line in (cgroup / "cpu.stat").read_text().splitlines())["usage_usec"]
            )
            observed["oom_kill"] = int(
                dict(line.split() for line in (cgroup / "memory.events").read_text().splitlines())["oom_kill"]
            )
        except (OSError, ValueError, KeyError):
            pass
        atomic(
            directory / "result.json",
            {
                "exit_code": code if code >= 0 else 128 - code,
                "ended_at": time.time(),
                "cleanup": "step-supervisor-complete",
                "observed": observed,
            },
        )
        return code if code >= 0 else 128 - code
    finally:
        os.close(payload_fd)
        for fd in handles:
            os.close(fd)


def step_exec(fd):
    # This module is loaded from immutable /nix/store under Python isolated mode.
    # No user environment, cwd, imports or executable is used before privilege drop.
    with os.fdopen(fd) as stream:
        payload = json.load(stream)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # subreaper INSIDE the destination PID namespace
        raise OSError("Cannot retain descendant lifetime")
    os.setgroups([])
    os.setgid(payload["gid"])
    os.setuid(payload["uid"])
    if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        raise OSError("Cannot disable privilege elevation")
    os.chdir(payload["cwd"])
    environment = {
        **payload["env"],
        "RESOURCE_JOB_ID": payload["id"],
        "RESOURCE_CPUSET": ",".join(str(cpu) for cpu in sorted(os.sched_getaffinity(0))),
    }
    # Retain old GPU marker semantics for model adapters during migration.
    budget = payload.get("budget", {})
    for name, field in (("RESOURCE_CPU", "cpu"), ("RESOURCE_RAM_MIB", "ram_mib"), ("RESOURCE_VRAM_MIB", "vram_mib")):
        environment[name] = str(budget.get(field, 0))
    if budget.get("vram_mib"):
        environment["GPU_LEASE_ID"] = payload["id"]
    child = subprocess.Popen(payload["command"], env=environment, start_new_session=True)

    def forward(signum, _frame):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, forward)
    result = 0
    while True:
        try:
            pid, status = os.wait()
        except ChildProcessError:
            break
        if pid == child.pid:
            result = os.waitstatus_to_exitcode(status)
    return result if result >= 0 else 128 - result


def run(args):
    if os.environ.get("RESOURCE_JOB_ID") or os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("Already inside a reservation; run directly within its existing budgets")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("Supply a foreground command after --")
    result = rpc(
        dict(
            action="submit",
            label=args.name,
            requested=dict(cpu=args.cpu, ram_mib=args.ram, vram_mib=args.vram or 0),
            mode="exclusive" if args.exclusive else "shared",
            priority=args.priority,
            category=args.category,
            origin=os.environ.get("AGENT_SANDBOX_INSTANCE") or "host",
            agent=os.environ.get("ORCA_AGENT_SESSION_ID")
            or os.environ.get("ORCA_SESSION_ID")
            or os.environ.get("ORCA_TERMINAL_HANDLE")
            or "unknown",
            worktree=os.environ.get("ORCA_WORKTREE_ID") or "unknown",
            project=args.project or "unknown",
            payload=dict(command=command, cwd=os.getcwd(), env=dict(os.environ)),
        )
    )
    job_id = result["id"]
    print(f"resource-run: submitted {job_id}", file=sys.stderr, flush=True)
    offsets = dict(stdout_offset=0, stderr_offset=0)
    last_reason = None
    queued_at = time.monotonic()
    interrupted = False

    def interrupt(_signal, _frame):
        nonlocal interrupted
        interrupted = True

    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        while True:
            result = rpc(dict(action="output", id=job_id, **offsets))
            for name, stream in (("stdout", sys.stdout), ("stderr", sys.stderr)):
                stream.write(result[name])
                stream.flush()
                offsets[name + "_offset"] = result[name + "_offset"]
            job = result["job"]
            if job["state"] in TERMINAL:
                # Drain output already written before Slurm terminal state.
                if not result["stdout"] and not result["stderr"]:
                    code = job["exit_code"]
                    if code is None:
                        return 130 if job["state"] == "cancelled" else 1
                    return code
                continue
            if job.get("wait_reason") != last_reason:
                last_reason = job.get("wait_reason")
                if last_reason:
                    print("resource-run: waiting: " + last_reason, file=sys.stderr, flush=True)
            timed_out = (
                getattr(args, "timeout", None) is not None
                and job["state"] in ("queued", "pending")
                and time.monotonic() - queued_at >= args.timeout
            )
            if interrupted or timed_out:
                try:
                    rpc(
                        dict(
                            action="cancel" if job["state"] in ("queued", "pending") else "terminate",
                            id=job_id,
                            revision=job["revision"],
                            confirm=True,
                        )
                    )
                    interrupted = False
                except RuntimeError:
                    # Revision changed; retry against the next observed authoritative version.
                    pass
            time.sleep(0.5)
    except (OSError, RuntimeError):
        print(
            f"resource-run: connection lost; job {job_id} may still run; inspect/cancel by ID, do not resubmit",
            file=sys.stderr,
        )
        raise
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def compat(argv):
    parser = argparse.ArgumentParser(description="Legacy GPU client using the authoritative Slurm queue")
    if not argv or argv[0] not in ("run", "game", "status", "serve-telemetry"):
        parser.error("Select run, game, status or serve-telemetry")
    operation = argv[0]
    parser.add_argument("--exclusive", action="store_true")
    parser.add_argument("--vram", type=size)
    parser.add_argument("--name", default="Legacy GPU workload")
    parser.add_argument("--timeout", type=float)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv[1:])
    args.operation = operation
    if args.operation == "serve-telemetry":
        raise RuntimeError("Legacy GPU telemetry disabled under Slurm authority")
    if args.operation == "status":
        value = rpc(dict(action="status"))
        print(json.dumps(value, indent=2))
        return 0
    if args.operation == "game":
        args.exclusive = True
    if not args.exclusive and not args.vram:
        raise ValueError("Supply --vram or --exclusive")
    args.cpu, args.ram, args.project = 1, 4096, None
    args.category = "game" if args.operation == "game" else "other"
    args.priority = "game" if args.operation == "game" else "background"
    print(
        "gpu-scheduler: compatibility reservation includes 1 Slurm CPU and 4GiB RAM; use resource-run for explicit budgets",
        file=sys.stderr,
    )
    return run(args)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "compat":
        return compat(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    runner = actions.add_parser("run")
    runner.add_argument("--cpu", type=int, required=True)
    runner.add_argument("--ram", type=size, required=True)
    runner.add_argument("--vram", type=size)
    runner.add_argument("--exclusive", action="store_true")
    runner.add_argument("--name", required=True)
    runner.add_argument("--category", choices=("build", "inference", "render", "game", "other"), default="other")
    runner.add_argument("--priority", choices=("background", "interactive", "game"), default="background")
    runner.add_argument("--project")
    runner.add_argument(
        "--timeout", type=float, help="Queue timeout in seconds; cancellation is confirmed through Slurm"
    )
    runner.add_argument("command", nargs=argparse.REMAINDER)
    actions.add_parser("status").add_argument("--json", action="store_true")
    control = actions.add_parser("control")
    control.add_argument("operation", choices=("cancel", "terminate", "pause", "resume"))
    control.add_argument("id", nargs="?")
    control.add_argument("--revision", type=int)
    control.add_argument("--confirm", action="store_true")
    model = actions.add_parser("model")
    model.add_argument("state", choices=("loading", "ready", "busy", "idle", "unloaded"))
    model.add_argument("--name", required=True)
    service = actions.add_parser("daemon")
    service.add_argument("--config", required=True)
    actions.add_parser("step").add_argument("directory")
    actions.add_parser("step-exec").add_argument("fd", type=int)
    args = parser.parse_args()
    if args.action == "run":
        return run(args)
    if args.action == "daemon":
        return daemon(args.config)
    if args.action == "step":
        return step(args.directory)
    if args.action == "step-exec":
        return step_exec(args.fd)
    if args.action == "model":
        job_id = os.environ.get("RESOURCE_JOB_ID")
        if not job_id:
            raise RuntimeError("Report model lifecycle from inside its reservation")
        print(json.dumps(rpc(dict(action="model-event", id=job_id, state=args.state, model_label=args.name))))
        return 0
    if args.action == "control":
        print(json.dumps(rpc(dict(action=args.operation, id=args.id, revision=args.revision, confirm=args.confirm))))
        return 0
    value = rpc(dict(action="status"))
    if args.json:
        print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
    else:
        print(f"Slurm resource queue: {value['mode']}, policy {value['policy_version']}, revision {value['revision']}")
        for job in value["jobs"]:
            print(f"{job['id']} {job['state']:8} {job['label']} {job['requested']}")
            if job["wait_reason"]:
                print("  " + job["wait_reason"])
        for error in value["errors"] + value["telemetry"]["errors"]:
            print("Unavailable: " + error)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
        # Errors from arbitrary workloads never flow into status or journal here.
        print("resource-scheduler: " + str(error), file=sys.stderr)
        sys.exit(1)
