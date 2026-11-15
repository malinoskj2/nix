#!/usr/bin/env python3
"""Capture the real backend serializer with simulated Slurm/telemetry, without a daemon.

Usage: python3 capture-backend-status.py /path/to/resource_scheduler.py output.json
No Slurm commands, GPU work, journal writes or imports into another checkout occur.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
source, destination = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("resource_scheduler", source)
backend_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend_module)
NOW = 1794747600
journal = []
clock = [NOW]


class Journal:
    def __init__(self, *_):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def sendto(self, data, address):
        assert address == "/run/systemd/journal/socket"
        fields = dict(line.split("=", 1) for line in data.decode().splitlines())
        journal.append(fields)


class Slurm:
    def __init__(self):
        self.rows = {}

    def submit(self, job, directory):
        identity = str(len(self.rows) + 1)
        self.rows[identity] = dict(job_id=int(identity), name="rs-" + job["id"], job_state=["PENDING"])
        return identity

    def jobs(self):
        return list(self.rows.values())

    def detail(self, identity):
        return self.rows[identity]

    def release(self, identity):
        self.rows[identity]["job_state"] = ["RUNNING"]

    def cancel(self, identity):
        self.rows[identity]["job_state"] = ["CANCELLED"]


snapshot = dict(sampled_at=NOW, errors=[], pressure=dict(cpu=None, memory=None, io=None),
                ram=dict(total_mib=31744, available_mib=20480),
                gpu=dict(total_mib=32768, free_mib=18432, used_mib=14336,
                         utilization_percent=None, allocations_mib={}), cgroups={})
scenarios = {}
with tempfile.TemporaryDirectory() as directory, patch.object(backend_module.socket, "socket", Journal), \
     patch.object(backend_module.time, "time", side_effect=lambda: clock[0]), \
     patch.object(backend_module.uuid, "uuid4", side_effect=[uuid.UUID(int=i) for i in range(1, 20)]):
    slurm = Slurm()
    backend = backend_module.Backend(dict(state_dir=directory, allowed_uid=1000, allowed_gid=100,
                                         stability_seconds=0, history_limit=1, cgroup_root=str(Path(directory) / "cgroups"), game_marker_path=str(Path(directory) / "game-marker")), slurm, lambda: copy.deepcopy(snapshot))

    backend.state["profile_salt"] = "deterministic-fixture-only"

    def submit(label, cpu=2, vram=0, mode="shared", priority="background", category="build"):
        return backend.handle(dict(version=1, action="submit", label=label,
            requested=dict(cpu=cpu, ram_mib=4096, vram_mib=vram), mode=mode, priority=priority,
            category="game" if priority == "game" else category, agent="fixture-agent",
            worktree="fixture-worktree", project="fixture-project", origin="host",
            payload=dict(command=["true"], cwd=directory, env={})), 1000)["id"]

    try:
        exclusive = submit("Unknown-size exclusive GPU workload", mode="exclusive")
        backend.tick()
        backend.tick()
        scenarios["exclusive_running"] = copy.deepcopy(backend.status())
        job = next(j for j in backend.state["jobs"] if j["id"] == exclusive)
        slurm.cancel(job["slurm_job_id"])
        backend.tick()
        background = submit("Existing CPU build", cpu=6)
        backend.tick()
        backend.tick()
        game = submit("Game session", mode="exclusive", priority="game")
        scenarios["game_pending"] = copy.deepcopy(backend.status())
        job = next(j for j in backend.state["jobs"] if j["id"] == background)
        slurm.cancel(job["slurm_job_id"])
        backend.tick()
        backend.tick()
        backend.tick()
        scenarios["game_running"] = copy.deepcopy(backend.status())
        job = next(j for j in backend.state["jobs"] if j["id"] == game)
        slurm.cancel(job["slurm_job_id"])
        backend.tick()
        model_job = submit("Owner-reported model server", vram=4096, category="inference")
        backend.tick()
        backend.tick()
        job = next(j for j in backend.state["jobs"] if j["id"] == model_job)
        allocation = job["slurm_job_id"]
        clock[0] = NOW + 2
        snapshot.update(sampled_at=clock[0], cpu=dict(total_ticks=1000, busy_ticks=400, logical_cpus=16, host_actual=None), swap=dict(pages_in=13, pages_out=7))
        snapshot["ram"]["swap_used_mib"] = 512
        snapshot["cgroups"][allocation] = {"cpu_usec": 0, "memory.current": 2048, "memory.peak": 3072}
        snapshot["gpu"]["allocations_mib"] = {allocation: 4096}
        backend.tick()
        scenarios["telemetry_first_sample"] = copy.deepcopy(backend.status())
        clock[0] = NOW + 4
        snapshot["sampled_at"] = clock[0]
        snapshot["cpu"].update(total_ticks=1100, busy_ticks=460)
        snapshot["cgroups"][allocation]["cpu_usec"] = 2000000
        backend.tick()
        scenarios["telemetry_measured"] = copy.deepcopy(backend.status())
        for state, offset in (("loading", 4), ("ready", 7), ("busy", 8), ("idle", 9), ("unloaded", 11)):
            clock[0] = NOW + offset
            backend.handle(dict(version=1, action="model-event", id=model_job, state=state, model_label="Fixture model"), 1000)
            scenarios["model_" + state] = copy.deepcopy(backend.status())
    finally:
        os.close(backend.lock_fd)

output = dict(provenance=dict(generator="capture-backend-status.py", backend_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    execution="Real Backend.submit/tick/status serializer; simulated Slurm and deterministic host telemetry; captured native journal datagrams"),
    scenarios=scenarios, journal_submission=next(fields for fields in journal if fields["RESOURCE_EVENT"] == "submission"))
destination.write_text(json.dumps(output, indent=2) + "\n")
