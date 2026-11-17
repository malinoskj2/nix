"""Slurm admission and explicit, systemd-supervised unmanaged host execution."""

import argparse
import contextlib
import ctypes
import fcntl
import json
import hashlib
import hmac
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
import xml.etree.ElementTree as ET

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
    adaptive_ram=False,
    large_gpu_lane=False,
    large_lane_project_ids=[],
    ram_capacity_mib=24576,
    ram_startup_seconds=30,
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
        "ram_capacity_mib",
        "ram_startup_seconds",
        "vram_headroom_mib",
        "gpu_capacity_mib",
        "history_limit",
    ):
        if type(config[key]) is not int or config[key] < 0:
            raise ValueError("Invalid nonnegative integer configuration: " + key)
    identifiers = config["large_lane_project_ids"]
    if not isinstance(identifiers, list) or any(
        not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,38}", value) for value in identifiers
    ):
        raise ValueError("Lane project identifiers must be decimal strings")
    if type(config["adaptive_ram"]) is not bool or type(config["large_gpu_lane"]) is not bool:
        raise ValueError("Invalid adaptive RAM policy")
    if (
        config["allowed_uid"] == 0
        or config["cpu_capacity"] < 1
        or config["ram_capacity_mib"] < 1
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


def gpu_process_allocations(xml, gpu_uuid, proc_root=Path("/proc")):
    """Include graphics as well as compute contexts; unknown memory stays unknown."""
    try:
        devices = [gpu for gpu in ET.fromstring(xml).findall("gpu") if gpu.findtext("uuid") == gpu_uuid]
    except ET.ParseError as error:
        raise ValueError("Invalid GPU process telemetry") from error
    if len(devices) != 1 or devices[0].find("processes") is None:
        raise ValueError("GPU process list unavailable")
    amounts, seen = {}, set()
    for process in devices[0].findall("processes/process_info"):
        pid = process.findtext("pid", "")
        memory = re.fullmatch(r"(\d+) MiB", process.findtext("used_memory", ""))
        if not pid.isdecimal() or memory is None or pid in seen:
            raise ValueError("Unknown or duplicate GPU process memory")
        seen.add(pid)
        group = (proc_root / pid / "cgroup").read_text()
        match = re.search(r"(?:/|_)job[_-](\d+)(?:/|\b)", group)
        if not match:
            match = re.search(r"(?:^|\n)0::/system\.slice/resource-large-([a-f0-9]{32})\.service(?:/|\n|$)", group)
        if match:
            amounts[match[1]] = amounts.get(match[1], 0) + int(memory[1])
    return amounts


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
        amounts = gpu_process_allocations(checked(["nvidia-smi", "--id=0", "--query", "--xml-format"]), gpu)
        if sum(amounts.values()) > used:
            raise ValueError("GPU attribution exceeds device usage")
        result["gpu"].update(
            allocations_mib=amounts, attribution_confidence="cgroup-gpu-processes", process_inventory_complete=True
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        result["errors"].append("GPU telemetry or process attribution unavailable")
    # Cgroup v2 high-water marks are authoritative where available; missing stays null.
    result["cgroups"] = {}
    try:
        for path in list(Path("/sys/fs/cgroup").glob("system.slice/*slurmstepd.scope/job_*")) + list(
            Path("/sys/fs/cgroup").glob("system.slice/resource-large-*.service")
        ):
            match = re.fullmatch(r"job_(\d+)", path.name) or re.fullmatch(
                r"resource-large-([a-f0-9]{32})\.service", path.name
            )
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


def ram_allowance(job, config, now=None):
    """Additional growth allowance, never a change to Slurm's allocation/limit."""
    now = time.time() if now is None else now
    limit = job["requested"]["ram_mib"]
    current = job["observed"].get("ram_mib")
    strict = max(0, limit - (current or 0))
    samples = job.get("ram_samples", [])
    peak = job["observed"].get("ram_peak_mib")
    if (
        not config.get("adaptive_ram")
        or job.get("memory_policy") == "strict"
        or job.get("ram_learning_blocked")
        or job["state"] != "running"
        or current is None
        or peak is None
        or len(samples) < 3
        or now - samples[-1][0] > max(10, config["poll_seconds"] * 3)
        or now - samples[-1][0] < 0
        or now - job.get("ram_observed_since", now) < config["ram_startup_seconds"]
    ):
        return strict, "strict/startup/unknown"
    # Retain the full observed high-water mark, including idle-after-load phases.
    baseline = max(current, peak, job.get("learned_ram_peak_mib") or 0)
    growth = max((max(0, b[1] - a[1]) / (b[0] - a[0]) for a, b in zip(samples, samples[1:]) if b[0] > a[0]), default=0)
    margin = max(1024, baseline * 0.25, growth * 15)
    return min(strict, max(0, baseline + margin - current)), "adaptive"


def automatic_profile(request, salt):
    payload = request["payload"]
    scope = payload.get("profile_scope") or payload["cwd"]
    relative = payload.get("profile_relative_cwd") or "."
    if not isinstance(scope, str) or not isinstance(relative, str):
        raise ValueError("Invalid private workload scope")

    def digest(value):
        return hmac.new(salt.encode(), json.dumps(value, sort_keys=True).encode(), hashlib.sha256).hexdigest()[:32]

    project = request.get("project")
    if (
        not isinstance(project, str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}", project)
        or project == "unknown"
    ):
        project = "repo-" + digest(scope)
    # Exact argv is intentionally opaque, including shell snippets and arguments.
    # Environment/content changes still require explicit variants for reliable reuse.
    return dict(
        project=project,
        name="auto-v1",
        variant=digest(
            [
                project,
                relative,
                payload["command"],
                request["requested"]["cpu"],
                request.get("category"),
                "sandbox" if request.get("origin", "host") != "host" else "host",
            ]
        ),
    )


def workload_scope():
    """Client-side Git discovery; never run repository commands in the root daemon."""
    cwd = os.getcwd()
    try:
        output = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
            check=True,
            env=SAFE_ENV,
        ).stdout.splitlines()
        common, root = output
        return dict(profile_scope=str(Path(common).resolve()), profile_relative_cwd=os.path.relpath(cwd, root))
    except (OSError, ValueError, subprocess.SubprocessError):
        return dict(profile_scope=cwd, profile_relative_cwd=".")


def lane_project_id(job):
    project = job.get("project")
    if not isinstance(project, str) or not project or project == "unknown":
        return None
    digest = hashlib.sha256(("resource-lane-project-v1\0" + project).encode()).digest()
    return str(int.from_bytes(digest[:16], "big"))


def large_gpu_job(job, config):
    if not config.get("large_gpu_lane") or not managed(job) or job.get("memory_policy") == "strict":
        return False
    # A running managed lane keeps its slot even if configuration changes.
    if job.get("execution") == "large":
        return True
    if lane_project_id(job) in config.get("large_lane_project_ids", []):
        return True
    return bool(
        not job.get("explore")
        and job["requested"]["vram_mib"]
        and (
            job.get("large_gpu")
            or job["mode"] == "exclusive"
            or job["requested"]["vram_mib"] >= min(8192, config["gpu_capacity_mib"] / 2)
        )
    )


def large_gpu_reason(job, jobs, snapshot, config):
    active = [item for item in jobs if item["state"] in ACTIVE and managed(item)]
    if any(item["state"] == "unknown" for item in active):
        return "Slurm state unknown; large GPU lane held until reconciled"
    if any(large_gpu_job(item, config) for item in active):
        return "Large GPU lane occupied; smaller jobs may pass"
    sampled = snapshot.get("sampled_at")
    memory = snapshot.get("pressure", {}).get("memory")
    available = snapshot["ram"].get("available_mib")
    free = snapshot["gpu"].get("free_mib")
    if (
        sampled is None
        or not 0 <= time.time() - sampled <= max(10, config["poll_seconds"] * 3)
        or available is None
        or free is None
        or not memory
        or memory.get("full", {}).get("avg10") is None
        or memory.get("some", {}).get("avg10") is None
    ):
        return "Resource telemetry unavailable or stale; large GPU lane held"
    if available < 1024 or free < 512:
        return "Critical memory shortage; large GPU lane needs 1 GiB host RAM and 512 MiB free VRAM"
    if memory["full"]["avg10"] >= 10 or memory["some"]["avg10"] >= 50:
        return "Severe memory pressure; large GPU lane held"
    return None


def admission_reason(job, jobs, snapshot, config):
    """Fail closed; unknown managed actual gets no credit against reservations."""
    if large_gpu_job(job, config):
        return large_gpu_reason(job, jobs, snapshot, config)
    running = [item for item in jobs if item["state"] in ACTIVE and managed(item)]
    request = job["requested"]
    if any(item["state"] == "unknown" for item in running):
        return "Slurm state unknown; retaining reservations until reconciled"
    # Pending grants retain their full allowances below, without a blanket FIFO hold.
    game_active = any(managed(item) and item["priority"] == "game" and item["state"] not in TERMINAL for item in jobs)
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
    if config.get("adaptive_ram"):
        memory_pressure = snapshot.get("pressure", {}).get("memory")
        if not memory_pressure or memory_pressure.get("full", {}).get("avg10") is None:
            return "Memory pressure telemetry unavailable; adaptive admissions stopped"
        sampled = snapshot.get("sampled_at")
        if sampled is None or not 0 <= time.time() - sampled <= max(10, config["poll_seconds"] * 3):
            return "Host memory telemetry stale; adaptive admissions stopped"
        if (
            sum(item["requested"]["ram_mib"] for item in running if slurm_managed(item)) + request["ram_mib"]
            > config["ram_capacity_mib"]
        ):
            return "Slurm RAM reservation capacity exhausted"
    outstanding = sum(ram_allowance(item, config)[0] for item in running)
    host_growth = snapshot["ram"].get("growth_buffer_mib", 0) if config.get("adaptive_ram") else 0
    if available - config["ram_headroom_mib"] - outstanding - host_growth < request["ram_mib"]:
        return (
            "Insufficient RAM after growth allowances and desktop headroom"
            if config.get("adaptive_ram")
            else "Insufficient RAM after unused reservations and desktop headroom"
        )
    if not request["vram_mib"]:
        return None
    if snapshot.get("game_active"):
        return "External GameMode is active; waiting for exclusive GPU access"
    gpu_jobs = [item for item in running if item["requested"]["vram_mib"]]
    if any(item.get("explore") for item in gpu_jobs):
        return "GPU exploration is measuring its peak; CPU-only jobs may pass"
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


def external_block_reason(job, jobs, snapshot, config):
    """Only bypass a barrier when managed completion cannot resolve its shortage."""
    active = [item for item in jobs if item["state"] in ACTIVE and managed(item)]
    if any(item["state"] != "running" for item in active):
        return None
    request = job["requested"]
    available = snapshot["ram"]["available_mib"]
    ram = [item["observed"].get("ram_mib") for item in active]
    if available is not None and all(value is not None for value in ram):
        if available + sum(ram) - config["ram_headroom_mib"] < request["ram_mib"]:
            return "Host RAM shortage remains after running jobs finish; smaller jobs may pass"
    game_active = snapshot.get("game_active") or any(
        managed(item) and item["priority"] == "game" and item["state"] == "queued" for item in jobs
    )
    if game_active and job["priority"] != "game" and request["cpu"] > config["game_cpu_capacity"]:
        return "Game CPU limit remains after running jobs finish; smaller jobs may pass"
    if request["vram_mib"]:
        if snapshot.get("game_active"):
            return "External GameMode blocks GPU admission; CPU-only jobs may pass"
        free = snapshot["gpu"]["free_mib"]
        if free is None:
            return "GPU telemetry unavailable; CPU-only jobs may pass"
        vram = [item["observed"].get("vram_mib") for item in active if item["requested"]["vram_mib"]]
        if all(value is not None for value in vram):
            needed = 1 if job.get("vram_auto") else request["vram_mib"]
            if free + sum(vram) - config["vram_headroom_mib"] < needed:
                return "Host VRAM shortage remains after running jobs finish; smaller jobs may pass"
    return None


def profile_identity(request):
    profile = request.get("profile")
    if profile is None:
        if request.get("variant") is not None:
            raise ValueError("Variant requires a profile")
        return None
    identity = {"project": request.get("project"), "name": profile, "variant": request.get("variant")}
    if any(
        not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}", value)
        for value in identity.values()
    ):
        raise ValueError(
            "Profiles require explicit project, profile and variant identifiers (1-80 safe characters each)"
        )
    return identity


PROFILE_LIMIT = 512
DELIVERED_REVIEW_SECONDS = 24 * 3600


def new_profile(identity):
    return dict(
        identity=identity,
        runs=0,
        successes=0,
        failures=0,
        consecutive_probe_failures=0,
        ram_peak_mib=None,
        vram_peak_mib=None,
        last=None,
    )


def public_profile(record):
    last = record["last"] or {}
    usable = last.get("state") == "completed" and last.get("exit_code") == 0 and not last.get("failure")

    def budget(value):
        return math.ceil(max(value * 1.25, value + 512) / 256) * 256 if value is not None else None

    return {
        **record,
        "recommendation": {
            "ram_mib": budget(record["ram_peak_mib"]) if usable else None,
            "vram_mib": (
                0
                if not last.get("gpu_requested")
                else budget(record["vram_peak_mib"])
                if last.get("gpu_complete")
                else None
            )
            if usable
            else None,
            "mode": "shared",
            "margin": "25% or 512 MiB, whichever is larger; rounded up to 256 MiB",
            "advisory": "Observed workload settings only; sampled GPU peaks can miss short spikes. Review before declaring budgets.",
        },
    }


def failure_kind(job, directory):
    if job.get("exploration_stop_reason"):
        return "exploration_headroom"
    if job["state"] == "cancelled":
        return "cancelled"
    terminal = job.get("slurm_terminal_state", [])
    if isinstance(terminal, str):
        terminal = [terminal]
    if "OUT_OF_MEMORY" in terminal or (job["observed"].get("oom_kill") or 0) > 0:
        return "ram_oom"
    if "TIMEOUT" in terminal:
        return "time_limit"
    if job["state"] == "completed" and job.get("exit_code") == 0:
        return None
    # Diagnostic hints, never classify every nonzero exit or SIGKILL as an OOM.
    try:
        with (directory / "stderr").open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 65536))
            stderr = stream.read(65536).decode(errors="replace").lower()
        if any(
            text in stderr
            for text in (
                "cuda out of memory",
                "cuda error: out of memory",
                "torch.outofmemoryerror",
                "vk_error_out_of_device_memory",
            )
        ):
            return "gpu_oom_reported"
    except OSError:
        pass
    return "command_failed"


def queue_key(job, now, config=None):
    return (
        0 if job.get("run_next_requested_at") is not None else 1,
        -(job.get("run_next_requested_at") or 0),
        0 if large_gpu_job(job, config or DEFAULTS) else 1,
        0 if job["priority"] == "game" else 1,
        0 if now - job["created_at"] >= 60 else 1,
        0 if now - job["created_at"] >= 60 or job["priority"] == "interactive" else 1,
        job["created_at"],
        job["id"],
    )


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
        if job.get("explore"):
            argv.append("--time=00:30:00")
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

    def hold(self, job_id):
        checked(["scontrol", "hold", job_id])

    def cancel(self, job_id):
        # TERM then Slurm's configured KillWait/KILL; cgroup cleanup remains Slurm-owned.
        checked(["scancel", job_id])


class HostRunner:
    """Systemd owns process lifetime; the queue admits the managed large lane."""

    def start(self, job, directory):
        properties = []
        if job.get("execution") == "large":
            budget = job["requested"]
            properties = [
                "--property=CPUAccounting=yes",
                "--property=MemoryAccounting=yes",
                f"--property=CPUQuota={budget['cpu'] * 100}%",
                f"--property=MemoryMax={budget['ram_mib']}M",
                "--property=MemorySwapMax=0",
                "--property=OOMPolicy=kill",
            ]
            if job.get("explore"):
                properties.append("--property=RuntimeMaxSec=1800")
        checked(
            [
                "systemd-run",
                "--quiet",
                "--no-block",
                "--unit=" + job["systemd_unit"],
                "--property=Type=exec",
                "--property=RemainAfterExit=yes",
                "--property=KillMode=control-group",
                "--property=TimeoutStopSec=10s",
                "--property=SendSIGKILL=yes",
                "--property=Restart=no",
                *properties,
                "--",
                sys.executable,
                "-I",
                str(Path(__file__).resolve()),
                "large-step"
                if job.get("execution") == "large"
                else "sandbox-step"
                if job.get("execution") == "sandbox"
                else "host-step",
                str(directory),
            ]
        )

    def status(self, unit):
        fields = "LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,ExecMainPID"
        return dict(
            line.split("=", 1)
            for line in checked(
                [
                    "systemctl",
                    "show",
                    unit,
                    "--property=" + fields,
                ]
            ).splitlines()
            if "=" in line
        )

    def stop(self, unit):
        checked(["systemctl", "stop", "--no-block", unit])

    def forget(self, unit):
        checked(["systemctl", "stop", unit])
        checked(["systemctl", "reset-failed", unit])


def managed(job):
    return job.get("execution", "slurm") in ("slurm", "large")


def slurm_managed(job):
    return job.get("execution", "slurm") == "slurm"


def slurm_held(row):
    # Slurm 25 wraps optional integers; older versions returned plain integers.
    priority = row.get("priority")
    if isinstance(priority, dict):
        priority = priority.get("number") if priority.get("set") and not priority.get("infinite") else None
    return slurm_state(row) == "pending" and type(priority) is int and priority == 0


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
    def __init__(self, config, slurm=None, sample=telemetry, host=None):
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
        self.state.setdefault("profiles", {})
        self.state.setdefault("profile_salt", os.urandom(32).hex())
        self.slurm = slurm or Slurm(self.config)
        self.host = host or HostRunner()
        self.sample = sample
        self.snapshot = None
        self.errors = []
        self.healthy_since = None
        self.last_sample_event = 0
        self.game_protection_errors = []
        self.game_active = False
        self.previous_cpu = None
        self.previous_ram = None
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
        self.prepare_notification(job)
        self.save()

    def submit(self, request, uid):
        if request.get("nested"):
            raise ValueError("Nested reservations are forbidden; run within the existing budget")
        if (
            sum(
                j.get("notification", {}).get("state") in ("pending", "sending", "unavailable", "delivered")
                for j in self.state["jobs"]
            )
            >= 500
        ):
            raise ValueError("Completion inbox is full; review resource-job notifications and acknowledge outcomes")
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
        large_gpu = request.get("large_gpu", False)
        if type(large_gpu) is not bool or (large_gpu and not req["vram_mib"]):
            raise ValueError("Large GPU lane requires a GPU workload")
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
        explore = request.get("explore", False)
        if type(explore) is not bool:
            raise ValueError("Invalid exploration mode")
        profile = profile_identity(request)
        if profile and profile["name"] == "auto-v1":
            raise ValueError("auto-v1 is reserved for automatic workload signatures")
        if explore and (profile is None or origin == "host" or mode != "shared" or request["priority"] == "game"):
            raise ValueError("Exploration requires a sandbox, project/profile/variant and shared non-game priority")
        automatic = profile is None
        if automatic:
            profile = automatic_profile(request, self.state["profile_salt"])
        memory_policy = request.get(
            "memory_policy", "adaptive" if self.config["adaptive_ram"] or self.config["large_gpu_lane"] else "strict"
        )
        if large_gpu and memory_policy == "strict":
            raise ValueError("Choose strict RAM reservations or the permissive large GPU lane, not both")
        if memory_policy not in ("strict", "adaptive"):
            raise ValueError("Unknown memory policy")
        if profile:
            key = json.dumps(profile, sort_keys=True)
            record = self.state["profiles"].get(key)
            if record is None and len(self.state["profiles"]) >= PROFILE_LIMIT:
                active_keys = {
                    json.dumps(j.get("profile"), sort_keys=True)
                    for j in self.state["jobs"]
                    if j["state"] not in TERMINAL
                }
                # Failed probe counters stay, so eviction can't reset the three-failure refusal.
                evictable = [
                    (k, v)
                    for k, v in self.state["profiles"].items()
                    if k not in active_keys and not v.get("consecutive_probe_failures")
                ]
                if evictable:
                    oldest = min(
                        evictable,
                        key=lambda pair: (
                            not pair[1].get("automatic"),
                            (pair[1].get("last") or {}).get("ended_at") or 0,
                        ),
                    )[0]
                    del self.state["profiles"][oldest]
                elif automatic:
                    profile = None  # Never block ordinary work merely because learning storage is full.
                else:
                    raise ValueError("Profile limit reached; reuse an existing workload profile")
            if explore and record and record.get("consecutive_probe_failures", 0) >= 3:
                raise ValueError(
                    "Three exploration failures; inspect the profile and use explicit budgets or changed workload settings"
                )
            if explore and any(j.get("profile") == profile and j["state"] not in TERMINAL for j in self.state["jobs"]):
                raise ValueError("This workload profile already has active work; wait without resubmitting")
        session = request.get("notify_session")
        if session is not None and (not isinstance(session, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", session)):
            raise ValueError("Invalid submitting session identity")
        waiter = request.get("waiter_token")
        if waiter is not None and (not isinstance(waiter, str) or not ID_RE.fullmatch(waiter)):
            raise ValueError("Invalid waiter identity")
        job_id = uuid.uuid4().hex
        job = dict(
            id=job_id,
            revision=1,
            label=clean_label(request["label"]),
            explore=explore,
            profile=profile,
            profile_automatic=automatic and profile is not None,
            memory_policy=memory_policy,
            large_gpu=large_gpu,
            notification={"state": "waiting", "session": session, "job_state": "queued", "generation": 0},
            waiter_token=waiter,
            waiter_until=time.time() + 30 if waiter else 0,
            owner_uid=uid,
            agent=clean_label(request.get("agent") or "unknown"),
            worktree=clean_label(request.get("worktree") or "unknown"),
            project=clean_label(request.get("project") or "unknown"),
            **{
                key: clean_label(request[key]) if request.get(key) is not None else None
                for key in ("repo", "worktree_name", "parent_worktree_name")
            },
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
            gpu_samples=0,
            gpu_missing_samples=0,
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
                "explore": explore,
                "stdout": str(directory / "stdout"),
                "stderr": str(directory / "stderr"),
            },
        )
        if profile:
            self.state["profiles"].setdefault(key, {**new_profile(profile), "automatic": automatic})
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
        for job in self.state["jobs"]:
            if not slurm_managed(job) and job["state"] not in TERMINAL:
                self.tick_host_job(job, now)
        try:
            rows = self.slurm.jobs()
            by_id = {str(row["job_id"]): row for row in rows}
            by_name = {row.get("name"): row for row in rows}
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            self.errors.append("Slurm unavailable; admissions stopped")
            self.healthy_since = None
            return
        for job in self.state["jobs"]:
            if job["state"] in TERMINAL or not slurm_managed(job):
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
                    job["slurm_terminal_state"] = row.get("job_state")
                    result_path = self.directory / job["id"] / "result.json"
                    if result_path.exists():
                        summary = json.loads(result_path.read_text())
                        job["exit_code"] = summary["exit_code"]
                        job["output_truncated"] = summary.get("output_truncated", {})
                        for key, value in summary.get("observed", {}).items():
                            if value is not None:
                                job["observed"][key] = (
                                    max(job["observed"].get(key) or 0, value)
                                    if key.endswith("peak_mib") or key == "oom_kill"
                                    else value
                                )
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
        for job in self.state["jobs"]:
            if job["state"] in ACTIVE and managed(job):
                metrics = self.snapshot.get("cgroups", {}).get(
                    job["id"] if job.get("execution") == "large" else job["slurm_job_id"], {}
                )
                observed = job["observed"]
                job["ram_peak_available"] = metrics.get("memory.peak") is not None
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
                if metrics.get("oom_kill") is not None:
                    observed["oom_kill"] = max(observed.get("oom_kill") or 0, metrics["oom_kill"])
                observed["cpu_set"] = metrics.get("cpu_set")
                amount = (
                    self.snapshot["gpu"]
                    .get("allocations_mib", {})
                    .get(
                        job["id"] if job.get("execution") == "large" else job["slurm_job_id"],
                        0 if self.snapshot["gpu"].get("process_inventory_complete") else None,
                    )
                )
                observed["vram_mib"] = amount
                if amount is not None:
                    observed["vram_peak_mib"] = max(observed["vram_peak_mib"] or 0, amount)
                    observed["attribution_confidence"] = self.snapshot["gpu"].get(
                        "attribution_confidence", "unavailable"
                    )
                if job["state"] == "running" and job["requested"]["vram_mib"]:
                    field = "gpu_samples" if amount is not None else "gpu_missing_samples"
                    job[field] = job.get(field, 0) + 1
        for job in self.state["jobs"]:
            if job["state"] in TERMINAL:
                self.record_profile(job)
        for job in self.state["jobs"]:
            if job["state"] != "running" or not managed(job):
                continue
            observed = job["observed"]
            if observed.get("ram_mib") is None or not job.get("ram_peak_available"):
                job["ram_missing_samples"] = job.get("ram_missing_samples", 0) + 1
                job["ram_samples"] = []
                job["ram_observed_since"] = now
            else:
                job["ram_good_samples"] = job.get("ram_good_samples", 0) + 1
                samples = job.get("ram_samples", [])
                if samples and now - samples[-1][0] > max(10, self.config["poll_seconds"] * 3):
                    samples = []
                if not samples:
                    job["ram_observed_since"] = now
                job["ram_samples"] = (samples + [[now, observed["ram_mib"]]])[-32:]
            record = self.state["profiles"].get(json.dumps(job.get("profile"), sort_keys=True), {})
            recent = [r for r in record.get("ram_runs", []) if now - r["at"] < 30 * 86400]
            job["learned_ram_peak_mib"] = max((r["peak"] for r in recent), default=None) if len(recent) >= 3 else None
            job["ram_learning_blocked"] = record.get("ram_learning_blocked", False)
            allowance, basis = ram_allowance(job, self.config, now)
            job["ram_admission"] = dict(
                growth_mib=allowance,
                basis=basis,
                learned_runs=len(recent),
                learned_peak_mib=job["learned_ram_peak_mib"],
            )
        self.protect_exploration()
        self.apply_game_protection()
        memory = self.snapshot["pressure"].get("memory")
        pressure_hold = bool(memory and memory.get("full", {}).get("avg10", 0) >= 1)
        if self.config["adaptive_ram"]:
            pressure_hold = (
                pressure_hold
                or not memory
                or memory.get("full", {}).get("avg10") is None
                or memory.get("some", {}).get("avg10", 0) >= 5
            )
        available = self.snapshot["ram"]["available_mib"]
        previous_ram = self.previous_ram
        self.snapshot["ram"]["growth_buffer_mib"] = (
            max(0, previous_ram[1] - available) * 15 / (now - previous_ram[0])
            if available is not None
            and previous_ram is not None
            and 0 < now - previous_ram[0] <= max(10, self.config["poll_seconds"] * 3)
            else 0
        )
        self.previous_ram = (now, available) if available is not None else None
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
        if not self.state["paused"]:
            for job in self.state["jobs"]:
                if (
                    slurm_managed(job)
                    and job["state"] == "pending"
                    and job.get("cleanup") != "cancellation-requested"
                    and large_gpu_job(job, self.config)
                    and not job.get("force_slurm")
                    and not any(e.get("event") == "force_run_requested" for e in job.get("events", []))
                    and not large_gpu_reason(
                        job, [j for j in self.state["jobs"] if j is not job], self.snapshot, self.config
                    )
                ):
                    self.start_large_handoff(job)
                    break
        queued = sorted(
            (job for job in self.state["jobs"] if job["state"] == "queued" and managed(job)),
            key=lambda j: queue_key(j, now, self.config),
        )
        barrier = None
        gpu_barrier = None
        bypassed = []
        for job in queued:
            if self.state["paused"]:
                reason = "New admissions paused by owner"
            elif job.get("cleanup") == "cancellation-requested":
                reason = "Waiting for Slurm cancellation"
            elif large_gpu_job(job, self.config):
                reason = large_gpu_reason(job, self.state["jobs"], self.snapshot, self.config)
                if reason:
                    bypassed.append(job["id"])
            elif self.game_protection_errors:
                reason = "Game CPU protection unavailable; new admissions stopped"
            elif self.healthy_since is None or now - self.healthy_since < self.config["stability_seconds"]:
                reason = "Pressure hold; waiting for stable desktop headroom"
            elif barrier:
                reason = "Behind earlier job " + barrier["id"]
            elif gpu_barrier and job["requested"]["vram_mib"]:
                reason = "Behind earlier GPU job " + gpu_barrier["id"]
            else:
                reason = admission_reason(job, self.state["jobs"], self.snapshot, self.config)
                if reason:
                    external = external_block_reason(job, self.state["jobs"], self.snapshot, self.config)
                    if reason == "Large GPU lane occupied; smaller jobs may pass":
                        bypassed.append(job["id"])
                    elif reason in (
                        "Exclusive GPU workload remains active",
                        "GPU exploration is measuring its peak; CPU-only jobs may pass",
                    ):
                        gpu_barrier = job
                        if "CPU-only" not in reason:
                            reason += "; CPU-only jobs may pass"
                        bypassed.append(job["id"])
                    elif external:
                        reason = external
                        bypassed.append(job["id"])
                    else:
                        barrier = job
            if reason != job["wait_reason"]:
                self.changed(job, reason=reason or "Slurm allocation released")
                if reason:
                    self.event(job, "waiting", reason=reason, snapshot=self.public_telemetry())
            if reason is None:
                try:
                    self.release_job(job, bypassed=bypassed)
                except (OSError, subprocess.SubprocessError):
                    self.errors.append("Slurm release failed; reconciliation required")
                break
        if now - self.last_sample_event >= 30 and any(j["state"] in ACTIVE for j in self.state["jobs"]):
            self.event({}, "sample", snapshot=self.public_telemetry())
            self.last_sample_event = now
        for job in self.state["jobs"]:
            self.prepare_notification(job)
            self.retire_delivered_notification(job)
        terminal = [j for j in self.state["jobs"] if j["state"] in TERMINAL]
        for job in terminal:
            self.record_profile(job)
        keep = {j["id"] for j in terminal[-self.config["history_limit"] :]}
        keep.update(
            j["id"]
            for j in terminal
            if j.get("notification", {}).get("state") in ("pending", "sending", "unavailable", "delivered")
        )
        for job in terminal:
            if job["id"] not in keep:
                directory = self.directory / job["id"]
                for name in ("stdout", "stderr", "result.json", "payload.json"):
                    (directory / name).unlink(missing_ok=True)
                directory.rmdir()
        self.state["jobs"] = [j for j in self.state["jobs"] if j["state"] not in TERMINAL or j["id"] in keep]
        self.save()

    def prepare_notification(self, job):
        notice = job.get("notification")
        if not notice:
            return
        state = job["state"]
        previous = notice.get("job_state")
        # Adopt old live notices without replaying historical terminal outcomes.
        if previous is None:
            if state in TERMINAL and notice["state"] != "waiting":
                return
            previous = "queued"
        if state == previous or state not in (*TERMINAL, "running", "unknown", "queued"):
            return
        job["notification"] = dict(
            state="pending",
            session=notice.get("session"),
            job_state=state,
            generation=notice.get("generation", 0) + 1,
            created_at=time.time(),
        )

    def retire_delivered_notification(self, job):
        # The session already holds a delivered wake-up. It needs review only for an outcome that
        # no waiting command returned, and only until the agent has had a day to handle it.
        notice = job.get("notification")
        if not notice or notice.get("state") != "delivered":
            return
        if job["state"] not in TERMINAL:
            reason = "Delivered state change; nothing to review"
        elif job.get("output_consumed_at"):
            reason = "Delivered; the waiting command also returned this outcome"
        elif time.time() >= notice.get("delivered_at", notice.get("created_at", 0)) + DELIVERED_REVIEW_SECONDS:
            reason = "Delivered and unreviewed for a day; retired"
        else:
            return
        notice.update(state="acknowledged", detail=reason)

    def notification_inbox(self):
        return [
            {
                "id": j["id"],
                "label": j["label"],
                "state": j["state"],
                "exit_code": j["exit_code"],
                "failure": j.get("failure"),
                "project": j["project"],
                "notification": {k: v for k, v in j["notification"].items() if k != "token"},
                "ready": time.time() >= j["notification"].get("created_at", 0) + 10,
            }
            for j in self.state["jobs"]
            if j.get("notification", {}).get("state") in ("pending", "sending", "unavailable", "delivered")
        ]

    def output_metadata(self, job):
        result = {}
        for name in ("stdout", "stderr"):
            path = self.directory / job["id"] / name
            result[name] = {
                "bytes": path.stat().st_size if path.exists() else 0,
                "truncated": job.get("output_truncated", {}).get(name),
            }
        return result

    def protect_exploration(self):
        """Only stop opted-in probes; never sacrifice another workload to fit one."""
        memory = self.snapshot["pressure"].get("memory")
        ram = self.snapshot["ram"].get("available_mib")
        free = self.snapshot["gpu"].get("free_mib")
        for job in self.state["jobs"]:
            if (
                not job.get("explore")
                or not managed(job)
                or job["state"] != "running"
                or job.get("cleanup") == "cancellation-requested"
            ):
                continue
            reason = None
            if job.get("execution") == "large":
                reason = large_gpu_reason(job, [], self.snapshot, self.config)
            elif (
                ram is None
                or ram < self.config["ram_headroom_mib"]
                or (memory and memory.get("full", {}).get("avg10", 0) >= 1)
            ):
                reason = "Host RAM headroom or pressure interrupted exploration"
            elif job["requested"]["vram_mib"] and (free is None or free < self.config["vram_headroom_mib"]):
                reason = "GPU headroom or unavailable telemetry interrupted exploration"
            if reason:
                try:
                    if job.get("execution") == "large":
                        self.host.stop(job["systemd_unit"])
                        job["host_cancel_requested"] = True
                    else:
                        self.slurm.cancel(job["slurm_job_id"])
                    job["cleanup"] = "cancellation-requested"
                    job["exploration_stop_reason"] = reason
                    self.event(job, "exploration_interrupted", reason=reason)
                    self.changed(job, reason=reason + "; awaiting execution cleanup")
                except (OSError, subprocess.SubprocessError):
                    self.errors.append("Exploration cancellation needs reconciliation: " + job["id"])

    def record_profile(self, job):
        if job.get("profile_recorded"):
            return
        job["failure"] = failure_kind(job, self.directory / job["id"])
        job["profile_recorded"] = True
        if not job.get("profile") or not managed(job):
            return
        key = json.dumps(job["profile"], sort_keys=True)
        record = self.state["profiles"].setdefault(key, new_profile(job["profile"]))
        success = job["state"] == "completed" and job.get("exit_code") == 0 and not job["failure"]
        record["runs"] += 1
        record["successes" if success else "failures"] += 1
        if success:
            record["consecutive_probe_failures"] = 0
            for field in ("ram_peak_mib", "vram_peak_mib"):
                value = job["observed"].get(field)
                if value is not None:
                    record[field] = max(record[field] or 0, value)
        elif job.get("explore"):
            record["consecutive_probe_failures"] += 1
        gpu_complete = (
            job.get("gpu_samples", 0) >= 2
            and (job["observed"].get("vram_peak_mib") or 0) > 0
            and job.get("gpu_missing_samples", 0) == 0
            and job["observed"].get("attribution_confidence") == "cgroup-gpu-processes"
        )
        if job["failure"] == "ram_oom":
            record["ram_learning_blocked"] = True
            record["ram_recovery_successes"] = 0
        peak = job["observed"].get("ram_peak_mib")
        if (
            success
            and peak is not None
            and job.get("ram_good_samples", 0) >= 2
            and not job.get("ram_missing_samples", 0)
        ):
            record["ram_runs"] = (
                record.get("ram_runs", [])
                + [
                    dict(
                        peak=peak,
                        at=job["ended_at"] or time.time(),
                        duration=max(0, (job["ended_at"] or time.time()) - (job["started_at"] or time.time())),
                    )
                ]
            )[-32:]
            record["ram_recovery_successes"] = record.get("ram_recovery_successes", 0) + 1
            if record["ram_recovery_successes"] >= 3:
                record["ram_learning_blocked"] = False
        record["last"] = dict(
            job_id=job["id"],
            state=job["state"],
            exit_code=job["exit_code"],
            failure=job["failure"],
            requested=dict(job["requested"]),
            ram_peak_mib=job["observed"].get("ram_peak_mib"),
            vram_peak_mib=job["observed"].get("vram_peak_mib"),
            gpu_complete=gpu_complete,
            gpu_requested=bool(job["requested"]["vram_mib"]),
            gpu_samples=job.get("gpu_samples", 0),
            gpu_missing_samples=job.get("gpu_missing_samples", 0),
            ended_at=job.get("ended_at"),
        )
        self.event(job, "profile_recorded", failure=job["failure"], profile=job["profile"])

    def start_large_handoff(self, job):
        # Hold first: a pending snapshot alone does not rule out a concurrent start.
        current = self.slurm.detail(job["slurm_job_id"])
        if current.get("name") != "rs-" + job["id"]:
            raise ValueError("Slurm identity mismatch before large lane hold")
        if slurm_state(current) != "pending":
            return
        self.slurm.hold(job["slurm_job_id"])
        row = self.slurm.detail(job["slurm_job_id"])
        if row.get("name") != "rs-" + job["id"]:
            raise ValueError("Slurm identity changed during large lane handoff")
        if not slurm_held(row):
            return
        job.update(
            execution="large", host_phase="cancelling-slurm", systemd_unit="resource-large-" + job["id"] + ".service"
        )
        self.changed(job, "pending", "Moving held allocation to the managed large lane")
        # Persist first; a restart retries cancellation, never command submission.
        self.slurm.cancel(job["slurm_job_id"])
        self.event(job, "large_lane_handoff", reason="Managed CPU/RAM limits; original execution namespace retained")

    def cancelled_service_gone(self, job, status):
        """Confirm cleanup after systemd collected an explicitly stopped unit."""
        if not (
            job.get("host_cancel_requested")
            and job.get("host_phase") == "running"
            and job.get("started_at") is not None
            and status.get("LoadState") == "not-found"
            and status.get("ActiveState") == "inactive"
            and status.get("SubState") == "dead"
            and status.get("ExecMainPID") == "0"
        ):
            return False
        unit = f"resource-{job['execution']}-{job['id']}.service"
        if job.get("systemd_unit") != unit:
            return False
        parent = Path(self.config["cgroup_root"]) / "system.slice"
        # Missing or unreadable cgroup telemetry must never count as cleanup.
        parent.stat()
        try:
            (parent / unit).stat()
        except FileNotFoundError:
            return True
        return False

    def tick_host_job(self, job, now):
        # Managed large jobs and both explicit overrides share service lifecycle.
        # Keep host_phase compatible with existing persisted overrides.
        target = job["execution"]
        description = "Managed large lane" if target == "large" else f"Unmanaged {target}"
        try:
            if job["host_phase"] == "cancelling-slurm":
                row = self.slurm.detail(job["slurm_job_id"])
                if row.get("name") != "rs-" + job["id"]:
                    raise ValueError("Slurm identity mismatch during service handoff")
                if target == "large" and slurm_held(row):
                    self.slurm.cancel(job["slurm_job_id"])
                    return
                if slurm_state(row) != "cancelled":
                    self.changed(job, reason=f"Waiting for confirmed Slurm cancellation before {target} launch")
                    return
                if job.get("host_cancel_requested"):
                    self.finish_host_job(job, "cancelled", 130, "slurm-terminal", now)
                    return
                if target == "large":
                    reason = (
                        "New admissions paused by owner"
                        if self.state["paused"]
                        else large_gpu_reason(
                            job, [j for j in self.state["jobs"] if j is not job], self.snapshot, self.config
                        )
                    )
                    if not self.config["large_gpu_lane"]:
                        reason = "Managed large lane disabled; waiting for operator"
                    if reason:
                        self.changed(job, reason=reason)
                        return
                payload_path = self.directory / job["id"] / "payload.json"
                payload = json.loads(payload_path.read_text())
                (self.directory / job["id"] / "result.json").unlink(missing_ok=True)
                payload["execution"] = target
                atomic(payload_path, payload)
                # Persist before launch. Never retry an ambiguous systemd request.
                job["host_phase"] = "starting"
                self.changed(job, "pending", f"Starting {description} process")
                self.host.start(job, self.directory / job["id"])
            status = self.host.status(job["systemd_unit"])
            if self.cancelled_service_gone(job, status):
                # systemd has discarded its exit status. Preserve unknown rather
                # than inventing a successful command exit; waiters return 130.
                self.finish_host_job(job, "cancelled", None, "systemd-unit-and-cgroup-removed", now)
                return
            if status.get("LoadState") != "loaded":
                raise ValueError("Host unit identity unavailable")
            required = ("ActiveState", "SubState", "Result", "ExecMainCode", "ExecMainStatus", "ExecMainPID")
            if any(key not in status for key in required):
                raise ValueError("Incomplete host service state")
            active, sub = status.get("ActiveState"), status.get("SubState")
            result_path = self.directory / job["id"] / "result.json"
            finished = active in ("inactive", "failed") or (active == "active" and sub == "exited")
            if finished and (
                status.get("ExecMainPID", "0") != "0" or result_path.exists() or status.get("Result") != "success"
            ):
                result = json.loads(result_path.read_text()) if result_path.exists() else {}
                code = result.get("exit_code")
                if code is None:
                    code = int(status.get("ExecMainStatus", "1"))
                    if status.get("ExecMainCode") in ("2", "3"):
                        code += 128
                    if status.get("Result") != "success" and code == 0:
                        code = 1
                if status.get("Result") != "success" and code == 0:
                    code = 137 if status.get("Result") == "oom-kill" else 1
                job["observed"].update(result.get("observed", {}))
                if target == "large" and status.get("Result") == "oom-kill":
                    job["observed"]["oom_kill"] = max(1, job["observed"].get("oom_kill") or 0)
                job["output_truncated"] = result.get("output_truncated", {})
                state = "cancelled" if job.get("host_cancel_requested") else "completed" if code == 0 else "failed"
                self.finish_host_job(job, state, code, "systemd-terminal", now)
                with contextlib.suppress(OSError, subprocess.SubprocessError):
                    self.host.forget(job["systemd_unit"])
            elif active == "active" and sub == "running":
                job["host_phase"] = "running"
                if job["state"] != "running":
                    job["started_at"] = job["started_at"] or now
                    self.changed(job, "running")
                    job["wait_reason"] = None
                    self.event(job, f"{target}_start", reason=f"{description} execution")
            elif active in ("activating", "deactivating") or finished:
                self.changed(job, "pending", "Waiting for host service lifecycle confirmation")
            else:
                raise ValueError("Unknown host service state")
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            self.changed(
                job, "unknown", f"{description} handoff or process state unknown; inspect service before retrying"
            )
            self.errors.append(f"{description} job reconciliation failed: " + job["id"])

    def finish_host_job(self, job, state, code, cleanup, now):
        job.update(state=state, exit_code=code, cleanup=cleanup, ended_at=now, wait_reason=None)
        self.event(job, "completion", exit_code=code, cleanup=cleanup, execution=job["execution"])
        (self.directory / job["id"] / "payload.json").unlink(missing_ok=True)
        self.record_profile(job)
        self.prepare_notification(job)
        self.changed(job)

    def release_job(self, job, *, force=False, bypassed=()):
        if not force and large_gpu_job(job, self.config):
            self.start_large_handoff(job)
            return
        if job.get("vram_auto"):
            # A forced exclusive job keeps the full configured usable GPU budget.
            if not force and not large_gpu_job(job, self.config):
                job["requested"]["vram_mib"] = (
                    min(self.config["gpu_capacity_mib"], self.snapshot["gpu"]["free_mib"])
                    - self.config["vram_headroom_mib"]
                )
            payload_path = self.directory / job["id"] / "payload.json"
            payload = json.loads(payload_path.read_text())
            payload["budget"] = dict(job["requested"])
            atomic(payload_path, payload)
        # Persist the attempt first: an ambiguous RPC must not release this job twice.
        if force:
            job["force_slurm"] = True
        job["released"] = True
        self.changed(job, "pending", "Waiting for Slurm allocation")
        try:
            self.slurm.release(job["slurm_job_id"])
        except (OSError, subprocess.SubprocessError):
            self.changed(job, "unknown", "Slurm release outcome unknown; retaining reservation")
            raise
        self.event(
            job,
            "admission",
            forced=force,
            large_gpu_lane=large_gpu_job(job, self.config),
            bypassed_job_ids=list(bypassed),
            snapshot=self.public_telemetry(),
        )
        self.save()

    def apply_game_protection(self):
        self.game_active = bool(self.snapshot.get("game_active")) or any(
            managed(j) and j["priority"] == "game" and j["state"] not in TERMINAL for j in self.state["jobs"]
        )
        previous_errors = self.game_protection_errors
        self.game_protection_errors = []
        running = [j for j in self.state["jobs"] if managed(j) and j["state"] == "running" and j["priority"] != "game"]
        total = sum(j["requested"]["cpu"] for j in running)
        for job in running:
            paths = list(
                Path(self.config["cgroup_root"]).glob("system.slice/*slurmstepd.scope/job_" + job["slurm_job_id"])
            )
            if job.get("execution") == "large":
                paths = [Path(self.config["cgroup_root"]) / "system.slice" / job["systemd_unit"]]
            if not paths:
                if self.game_active:
                    self.game_protection_errors.append("Slurm CPU cgroup unavailable for " + job["id"])
                continue
            try:
                for path in paths:
                    quota = (
                        f"{max(1000, int(100000 * self.config['game_cpu_capacity'] * job['requested']['cpu'] / total))} 100000"
                        if self.game_active and total > self.config["game_cpu_capacity"]
                        else f"{100000 * job['requested']['cpu']} 100000"
                        if job.get("execution") == "large"
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
            **{k: v for k, v in job.items() if k not in ("waiter_token", "ram_samples")},
            "requested": dict(job["requested"]),
            "lane_project_id": lane_project_id(job),
            "events": [{k: v for k, v in event.items() if k != "snapshot"} for event in job["events"][-8:]],
        }
        if job.get("notification"):
            result["notification"] = {k: v for k, v in job["notification"].items() if k != "token"}
        effective = job["requested"]["vram_mib"] if job.get("released") or job["state"] == "running" else None
        result["allocation"] = {
            "cpu": job["requested"]["cpu"],
            "ram_mib": job["requested"]["ram_mib"],
            "vram_mib": effective,
        }
        if not managed(job):
            result["allocation"] = None
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
        running = [j for j in self.state["jobs"] if j["state"] in ACTIVE and managed(j)]
        ram_actual = [j["observed"]["ram_mib"] for j in running]
        gpu_actual = [j["observed"]["vram_mib"] for j in running]
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
                "admission_policy": "adaptive" if self.config["adaptive_ram"] else "strict",
                "growth_allowance_mib": sum(ram_allowance(j, self.config)[0] for j in running),
                "slurm_capacity_mib": self.config["ram_capacity_mib"],
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
        queued = sorted(
            (j for j in jobs if managed(j) and j["state"] == "queued"),
            key=lambda j: queue_key(j, time.time(), self.config),
        )
        positions = {job["id"]: index + 1 for index, job in enumerate(queued)}
        mode = "manual_hold" if self.state["paused"] else "normal"
        if mode == "normal" and (
            self.healthy_since is None or time.time() - self.healthy_since < self.config["stability_seconds"]
        ):
            mode = "pressure_hold"
        if mode == "normal":
            for state, suffix in (("running", "running"), ("pending", "pending"), ("queued", "pending")):
                matching = [j for j in jobs if managed(j) and j["state"] == state and j["mode"] == "exclusive"]
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
                cancel=True,
                terminate=True,
                force_run=True,
                run_next=True,
                run_host=True,
                run_sandbox=True,
                exploration=True,
                profiles=True,
                job_inspection=True,
                completion_notifications=True,
                adaptive_ram=self.config["adaptive_ram"],
                large_gpu_lane=self.config["large_gpu_lane"],
                pause=True,
                resume=True,
                priority=False,
                unload=False,
                model_reports=True,
            ),
            telemetry=self.public_telemetry(),
            jobs=[
                {
                    **self.public_job(j),
                    "queue_position": positions.get(j["id"]),
                    "large_gpu_lane": large_gpu_job(j, self.config),
                }
                for j in jobs
                if j["state"] not in TERMINAL
            ],
            history=[
                {**self.public_job(j), "large_gpu_lane": large_gpu_job(j, self.config)}
                for j in reversed(jobs)
                if j["state"] in TERMINAL
            ],
            errors=self.errors,
            notifications=self.notification_inbox()[:100],
            notification_count=len(self.notification_inbox()),
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
        if action == "notifications":
            return {"notifications": self.notification_inbox()}
        if action == "profiles":
            identity = profile_identity(request)
            project = request.get("project")
            if project is not None and (
                not isinstance(project, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}", project)
            ):
                raise ValueError("Invalid profile project identifier")
            profiles = [
                public_profile(p)
                for p in self.state["profiles"].values()
                if (identity is None or p["identity"] == identity)
                and (project is None or p["identity"]["project"] == project)
            ]
            return {
                "profiles": sorted(profiles, key=lambda p: json.dumps(p["identity"], sort_keys=True)),
                "limit": PROFILE_LIMIT,
            }
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
        if action == "inspect":
            return {"job": self.public_job(job), "events": job["events"], "output": self.output_metadata(job)}
        if action == "watch":
            token = request.get("token")
            if not isinstance(token, str) or not ID_RE.fullmatch(token):
                raise ValueError("Invalid waiter identity")
            job["waiter_token"], job["waiter_until"] = token, time.time() + 30
            self.save()
            return {"id": job_id}
        if action in ("notification-claim", "notification-finish", "notification-ack"):
            notice = job.get("notification")
            if not notice:
                raise ValueError("No completion notification")
            if action == "notification-claim":
                due = notice.get("created_at", 0) + 10
                if (
                    notice["state"] != "pending"
                    or time.time() < due
                    or request.get("generation", notice.get("generation")) != notice.get("generation")
                ):
                    raise ValueError("Notification is claimed, superseded or not ready")
                # Durable intent BEFORE contacting Orca. A lost response never causes a second wake.
                notice.update(state="sending", token=uuid.uuid4().hex)
                self.save()
                return {"token": notice["token"]}
            if action == "notification-finish":
                if notice["state"] != "sending" or request.get("token") != notice.get("token"):
                    raise ValueError("Notification claim mismatch")
                state = request.get("state")
                if state not in ("delivered", "unavailable"):
                    raise ValueError("Invalid notification outcome")
                notice.update(state=state, detail=clean_label(request.get("detail", state)), delivered_at=time.time())
                notice.pop("token", None)
                self.retire_delivered_notification(job)
            else:
                if request.get("confirm") is not True:
                    if not request.get("token") or request["token"] != job.get("waiter_token"):
                        raise ValueError("Acknowledge with --confirm; waiter tokens only record output consumption")
                    # Compatibility with old clients: draining a CLI is not agent acknowledgement.
                    job["output_consumed_at"] = time.time()
                    self.retire_delivered_notification(job)
                    self.save()
                    return {"id": job_id, "state": notice["state"], "output_consumed": True}
                notice.update(state="acknowledged")
                notice.pop("token", None)
            self.save()
            return {"id": job_id, "state": notice["state"]}
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
            if (
                request.get("waiter_token")
                and request["waiter_token"] == job.get("waiter_token")
                and job.get("waiter_until", 0) < time.time() + 20
            ):
                job["waiter_until"] = time.time() + 30
                self.save()
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
            result["job"] = self.public_job(job)
            result["output"] = self.output_metadata(job)
            return result
        if action not in ("cancel", "terminate", "force-run", "run-next", "run-host", "run-sandbox"):
            raise ValueError("Unsupported control action")
        if request.get("confirm") is not True or request.get("revision") != job["revision"]:
            raise ValueError("Confirmation and current job revision required")
        if job["state"] in TERMINAL:
            raise ValueError("Job already finished")
        if not slurm_managed(job):
            if action not in ("cancel", "terminate"):
                raise ValueError("Service execution cannot be released or reordered in Slurm")
            if job["host_phase"] == "cancelling-slurm":
                job["host_cancel_requested"] = True
            else:
                if action != "terminate":
                    raise ValueError("Service process may have started; use terminate")
                self.host.stop(job["systemd_unit"])
                job["host_cancel_requested"] = True
            self.event(job, job["execution"] + "_termination_requested")
            self.changed(job)
            return {"id": job_id, "revision": job["revision"], "pending": True}
        if action == "cancel" and job["state"] not in ("queued", "pending"):
            raise ValueError("Running work requires terminate")
        if not job["slurm_job_id"]:
            raise ValueError("Unknown Slurm identity; cannot cancel safely")
        current = self.slurm.detail(job["slurm_job_id"])
        if current.get("name") != "rs-" + job["id"]:
            raise ValueError("Slurm allocation identity changed; refusing control")
        if action in ("force-run", "run-next", "run-host", "run-sandbox"):
            if (
                job["state"] != "queued"
                or job.get("released")
                or job.get("cleanup") == "cancellation-requested"
                or slurm_state(current) != "pending"
            ):
                raise ValueError("This action requires an unallocated queued job without a pending cancellation")
            if action in ("run-host", "run-sandbox"):
                target = "sandbox" if action == "run-sandbox" else "host"
                if target == "sandbox" and not re.fullmatch(r"agent-sandbox-[A-Za-z0-9_.-]{1,128}", job["origin"]):
                    raise ValueError("Run in sandbox requires a sandbox-origin job")
                # Cancellation is confirmed on a later tick before any command starts.
                self.slurm.cancel(job["slurm_job_id"])
                job.update(
                    execution=target,
                    host_phase="cancelling-slurm",
                    systemd_unit="resource-" + target + "-" + job["id"] + ".service",
                )
                self.event(job, target + "_run_requested", reason=f"Owner requested unmanaged {target} execution")
                self.changed(job, "pending", f"Waiting for Slurm cancellation before unmanaged {target} launch")
            elif action == "force-run":
                self.event(
                    job, "force_run_requested", reason="Owner overrides queue order, pressure and headroom policy"
                )
                self.release_job(job, force=True)
            else:
                # The most recent explicit request moves to the front.
                job["run_next_requested_at"] = time.time()
                self.event(
                    job, "run_next_requested", reason="Owner moved job to the front; resource checks still apply"
                )
                self.changed(job, reason="Run next requested; awaiting resource admission checks")
            return {"id": job_id, "revision": job["revision"], "pending": True}
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


def step(directory, host=False, sandbox=False, large=False):
    # Slurm or a transient systemd service runs this immutable root bootstrap.
    # Caller environment remains private data until privilege drop.
    if os.getuid() != 0 or not os.environ.get("INVOCATION_ID" if host or sandbox or large else "SLURM_JOB_ID"):
        raise RuntimeError("Step bootstrap must be launched by root Slurm or the host service")
    directory = Path(directory)
    payload_fd = os.open(directory / "payload.json", os.O_RDONLY | os.O_NOFOLLOW)
    handles = []
    try:
        with os.fdopen(os.dup(payload_fd)) as stream:
            payload = json.load(stream)
        if payload["id"] != directory.name or not ID_RE.fullmatch(directory.name):
            raise ValueError("Private payload identity mismatch")
        if large and payload.get("execution") != "large":
            raise ValueError("Managed large execution was not authorized")
        if host and payload.get("execution") != "host":
            raise ValueError("Unmanaged host execution was not authorized")
        if sandbox and payload.get("execution") != "sandbox":
            raise ValueError("Unmanaged sandbox execution was not authorized")
        os.lseek(payload_fd, 0, os.SEEK_SET)
        argv = [sys.executable, "-I", str(Path(__file__).resolve()), "step-exec", str(payload_fd)]
        if sandbox or (not host and payload["origin"] != "host"):
            argv, handles = namespace_command(payload, payload_fd)
        # Files are root-owned and private. Bound stored stdout/stderr independently.
        streams = {name: (directory / name).open("wb") for name in ("stdout", "stderr")}
        child = subprocess.Popen(
            argv, pass_fds=(payload_fd, *handles), env=SAFE_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        pipes = {child.stdout: streams["stdout"], child.stderr: streams["stderr"]}
        totals = {stream: 0 for stream in streams.values()}
        truncated = {stream: False for stream in streams.values()}
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
                truncated[stream] = truncated[stream] or len(chunk) > remaining
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
                "output_truncated": {name: truncated[stream] for name, stream in streams.items()},
                "observed": observed,
            },
        )
        return code if code >= 0 else 128 - code
    finally:
        os.close(payload_fd)
        for fd in handles:
            os.close(fd)


def execution_environment(payload):
    environment = dict(payload["env"])
    if payload.get("execution") in ("host", "sandbox"):
        for key in (
            "RESOURCE_JOB_ID",
            "GPU_LEASE_ID",
            "RESOURCE_CPU",
            "RESOURCE_RAM_MIB",
            "RESOURCE_VRAM_MIB",
            "RESOURCE_CPUSET",
            "RESOURCE_HOST_JOB_ID",
            "RESOURCE_SANDBOX_JOB_ID",
            "RESOURCE_EXPLORATORY",
        ):
            environment.pop(key, None)
        target = payload["execution"]
        if target == "sandbox":
            environment["AGENT_SANDBOX_INSTANCE"] = payload["origin"]
        else:
            environment.pop("AGENT_SANDBOX_INSTANCE", None)
        environment[f"RESOURCE_{target.upper()}_JOB_ID"] = payload["id"]
        environment["RESOURCE_EXECUTION_MODE"] = "unmanaged-" + target
        return environment
    environment["RESOURCE_EXECUTION_MODE"] = "managed-large" if payload.get("execution") == "large" else "slurm"
    environment.pop("RESOURCE_EXPLORATORY", None)
    if payload.get("explore"):
        environment["RESOURCE_EXPLORATORY"] = "1"
    environment.update(
        RESOURCE_JOB_ID=payload["id"], RESOURCE_CPUSET=",".join(str(cpu) for cpu in sorted(os.sched_getaffinity(0)))
    )
    budget = payload.get("budget", {})
    for name, field in (("RESOURCE_CPU", "cpu"), ("RESOURCE_RAM_MIB", "ram_mib"), ("RESOURCE_VRAM_MIB", "vram_mib")):
        environment[name] = str(budget.get(field, 0))
    if budget.get("vram_mib"):
        environment["GPU_LEASE_ID"] = payload["id"]
    return environment


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
    environment = execution_environment(payload)
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


def run_budgets(args):
    explore = getattr(args, "explore", False)
    cpu = args.cpu if args.cpu is not None else 2 if explore else None
    ram = args.ram if args.ram is not None else 4096 if explore else None
    gpu = getattr(args, "gpu", False)
    vram = args.vram if args.vram is not None else 1024 if explore and gpu else 0
    if cpu is None or ram is None:
        raise ValueError("Supply --cpu and --ram (only --explore supplies trial defaults)")
    if gpu and not explore:
        raise ValueError("--gpu is for exploration; normal runs must declare --vram or --exclusive")
    if explore and (args.exclusive or args.priority == "game"):
        raise ValueError("Exploration uses shared resources and non-game priority")
    return dict(cpu=cpu, ram_mib=ram, vram_mib=vram)


def run(args):
    if os.environ.get("RESOURCE_JOB_ID") or os.environ.get("GPU_LEASE_ID"):
        raise RuntimeError("Already inside a reservation; run directly within its existing budgets")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("Supply a foreground command after --")
    budgets = run_budgets(args)
    identity = profile_identity(
        dict(project=args.project, profile=getattr(args, "profile", None), variant=getattr(args, "variant", None))
    )
    if getattr(args, "explore", False) and (identity is None or not os.environ.get("AGENT_SANDBOX_INSTANCE")):
        raise ValueError("Exploration requires a sandbox and --project, --profile and --variant")
    waiter_token = uuid.uuid4().hex
    result = rpc(
        dict(
            action="submit",
            waiter_token=waiter_token,
            notify_session=os.environ.get("ORCA_AGENT_SESSION_ID") or os.environ.get("ORCA_SESSION_ID"),
            **({"memory_policy": args.memory_policy} if getattr(args, "memory_policy", None) else {}),
            large_gpu=getattr(args, "large_gpu", False),
            label=args.name,
            requested=budgets,
            explore=getattr(args, "explore", False),
            profile=getattr(args, "profile", None),
            variant=getattr(args, "variant", None),
            mode="exclusive" if args.exclusive else "shared",
            priority=args.priority,
            category=args.category,
            origin=os.environ.get("AGENT_SANDBOX_INSTANCE") or "host",
            agent=os.environ.get("ORCA_AGENT_SESSION_ID")
            or os.environ.get("ORCA_SESSION_ID")
            or os.environ.get("ORCA_TERMINAL_HANDLE")
            or "unknown",
            worktree=getattr(args, "worktree", None) or os.environ.get("ORCA_WORKTREE_ID") or "unknown",
            repo=getattr(args, "repo", None),
            worktree_name=getattr(args, "worktree_name", None),
            parent_worktree_name=getattr(args, "parent_worktree_name", None),
            project=args.project or "unknown",
            payload=dict(command=command, cwd=os.getcwd(), env=dict(os.environ), **workload_scope()),
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
            result = rpc(dict(action="output", id=job_id, waiter_token=waiter_token, **offsets))
            for name, stream in (("stdout", sys.stdout), ("stderr", sys.stderr)):
                stream.write(result[name])
                stream.flush()
                offsets[name + "_offset"] = result[name + "_offset"]
            job = result["job"]
            if job["state"] in TERMINAL:
                # Drain output already written before Slurm terminal state.
                if not result["stdout"] and not result["stderr"]:
                    code = job["exit_code"]
                    if job.get("notification"):
                        with contextlib.suppress(OSError, RuntimeError):
                            rpc(dict(action="notification-ack", id=job_id, token=waiter_token))
                    print(
                        f"resource-run: {job_id} {job['state']}; exit={code}; outcome={job.get('failure') or job['state']}; inspect: resource-job inspect {job_id}",
                        file=sys.stderr,
                    )
                    if job.get("profile"):
                        print(
                            "resource-run: profile "
                            + json.dumps(job["profile"])
                            + "; outcome="
                            + str(job.get("failure") or job["state"]),
                            file=sys.stderr,
                        )
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
                            action="cancel"
                            if job["state"] in ("queued", "pending")
                            and (slurm_managed(job) or job.get("host_phase") == "cancelling-slurm")
                            else "terminate",
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


def resource_job(args):
    if args.operation == "notifications":
        result = rpc(dict(action="notifications"))
        print(json.dumps(result, indent=2))
        return 0
    if not args.id or not ID_RE.fullmatch(args.id):
        raise ValueError("Supply the full job ID")
    if args.operation == "ack":
        print(json.dumps(rpc(dict(action="notification-ack", id=args.id, confirm=args.confirm))))
        return 0
    if args.operation == "inspect":
        result = rpc(dict(action="inspect", id=args.id))
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            job = result["job"]
            for label, value in (
                ("Job", job["id"]),
                ("Name", job["label"]),
                ("Repository", job.get("repo")),
                ("Worktree", job.get("worktree_name")),
                ("Parent worktree", job.get("parent_worktree_name")),
                ("State", job["state"]),
                ("Exit", job.get("exit_code")),
                ("Outcome", job.get("failure")),
                ("Waiting", job.get("wait_reason")),
                ("Request", job["requested"]),
                ("Observed", job["observed"]),
                ("Notification", job.get("notification")),
            ):
                print(f"{label}: {value if value is not None else 'unknown'}")
            print(f"Output: resource-job logs {args.id}")
        return 0
    if any(value < 0 for value in (args.stdout_offset, args.stderr_offset)):
        raise ValueError("Output offsets must be nonnegative")
    if args.timeout is not None and (not math.isfinite(args.timeout) or args.timeout <= 0):
        raise ValueError("Wait timeout must be positive and finite")
    token = uuid.uuid4().hex if args.operation == "wait" else None
    if token:
        rpc(dict(action="watch", id=args.id, token=token))
    offsets = dict(stdout_offset=args.stdout_offset, stderr_offset=args.stderr_offset)
    start = time.monotonic()
    while True:
        result = rpc(dict(action="output", id=args.id, waiter_token=token, **offsets))
        job = result["job"]
        if args.operation == "logs":
            if args.json:
                print(json.dumps(result), flush=True)
            else:
                for name, stream in (("stdout", sys.stdout), ("stderr", sys.stderr)):
                    if args.stream in ("both", name):
                        stream.write(result[name])
                        stream.flush()
        offsets = {name + "_offset": result[name + "_offset"] for name in ("stdout", "stderr")}
        drained = not result["stdout"] and not result["stderr"]
        if job["state"] in TERMINAL and drained:
            if token and job.get("notification"):
                with contextlib.suppress(OSError, RuntimeError):
                    rpc(dict(action="notification-ack", id=args.id, token=token))
            if args.operation == "wait":
                print(
                    json.dumps(job)
                    if args.json
                    else f"{args.id}: {job['state']}; exit={job['exit_code']}; outcome={job.get('failure') or job['state']}"
                )
                return job["exit_code"] if job["exit_code"] is not None else 130 if job["state"] == "cancelled" else 1
            return 0
        if args.operation == "logs" and drained and not args.follow:
            return 0
        if args.timeout is not None and time.monotonic() - start >= args.timeout:
            print("resource-job: observation timed out; job remains unchanged", file=sys.stderr)
            return 124
        if drained:
            time.sleep(0.5)


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
    runner.add_argument("--cpu", type=int)
    runner.add_argument("--ram", type=size)
    runner.add_argument("--vram", type=size)
    runner.add_argument("--exclusive", action="store_true")
    runner.add_argument(
        "--explore", action="store_true", help="Bounded 30-minute sandbox trial; defaults to 2 CPUs and 4GiB RAM"
    )
    runner.add_argument(
        "--gpu", action="store_true", help="Explore with an initial 1GiB shared GPU allocation, not a peak guarantee"
    )
    runner.add_argument("--profile", help="Stable workload name, without command arguments or secrets")
    runner.add_argument("--variant", help="Explicit workload settings/version identifier")
    runner.add_argument("--name", required=True)
    runner.add_argument("--category", choices=("build", "inference", "render", "game", "other"), default="other")
    runner.add_argument("--priority", choices=("background", "interactive", "game"), default="background")
    runner.add_argument(
        "--memory-policy",
        choices=("strict", "adaptive"),
        help="Strict peak reservations or host-enabled adaptive RAM admission",
    )
    runner.add_argument(
        "--large-gpu",
        action="store_true",
        help="Use the permissive single-large-GPU lane; only critical pressure/headroom gates and Slurm limits apply",
    )
    runner.add_argument("--project")
    runner.add_argument("--repo", help="Optional repository name for ownership display")
    runner.add_argument("--worktree", help="Optional exact Orca worktree ID; defaults to ORCA_WORKTREE_ID")
    runner.add_argument("--worktree-name", help="Optional Orca worktree display name")
    runner.add_argument("--parent-worktree-name", help="Optional parent display name, only for a child Orca worktree")
    runner.add_argument(
        "--timeout", type=float, help="Queue timeout in seconds; cancellation is confirmed through Slurm"
    )
    runner.add_argument("command", nargs=argparse.REMAINDER)
    actions.add_parser("status").add_argument("--json", action="store_true")
    profiles = actions.add_parser("profile")
    profiles.add_argument("--project")
    profiles.add_argument("--profile")
    profiles.add_argument("--variant")
    control = actions.add_parser("control")
    control.add_argument(
        "operation",
        choices=("cancel", "terminate", "force-run", "run-next", "run-host", "run-sandbox", "pause", "resume"),
    )
    control.add_argument("id", nargs="?")
    control.add_argument("--revision", type=int)
    control.add_argument("--confirm", action="store_true")
    job = actions.add_parser("job")
    job.add_argument("operation", choices=("inspect", "logs", "wait", "notifications", "ack"))
    job.add_argument("id", nargs="?")
    job.add_argument("--json", action="store_true")
    job.add_argument("--follow", action="store_true")
    job.add_argument("--stream", choices=("both", "stdout", "stderr"), default="both")
    job.add_argument("--stdout-offset", type=int, default=0)
    job.add_argument("--stderr-offset", type=int, default=0)
    job.add_argument("--timeout", type=float)
    job.add_argument("--confirm", action="store_true")
    model = actions.add_parser("model")
    model.add_argument("state", choices=("loading", "ready", "busy", "idle", "unloaded"))
    model.add_argument("--name", required=True)
    service = actions.add_parser("daemon")
    service.add_argument("--config", required=True)
    actions.add_parser("step").add_argument("directory")
    actions.add_parser("host-step").add_argument("directory")
    actions.add_parser("sandbox-step").add_argument("directory")
    actions.add_parser("large-step").add_argument("directory")
    actions.add_parser("step-exec").add_argument("fd", type=int)
    args = parser.parse_args()
    if args.action == "job":
        return resource_job(args)
    if args.action == "profile":
        print(
            json.dumps(
                rpc(dict(action="profiles", project=args.project, profile=args.profile, variant=args.variant)), indent=2
            )
        )
        return 0
    if args.action == "run":
        return run(args)
    if args.action == "daemon":
        return daemon(args.config)
    if args.action == "step":
        return step(args.directory)
    if args.action == "host-step":
        return step(args.directory, host=True)
    if args.action == "large-step":
        return step(args.directory, large=True)
    if args.action == "sandbox-step":
        return step(args.directory, sandbox=True)
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
