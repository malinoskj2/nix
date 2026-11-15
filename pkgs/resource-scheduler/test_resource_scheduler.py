import contextlib
import copy
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import resource_scheduler as rs


def snapshot(ram=20000, free=31000):
    return {
        "sampled_at": 1,
        "errors": [],
        "pressure": {"cpu": None, "memory": None, "io": None},
        "ram": {"available_mib": ram, "total_mib": 32000},
        "gpu": {
            "total_mib": 32768,
            "free_mib": free,
            "used_mib": 32768 - free if free is not None else None,
            "allocations_mib": {},
            "utilization_percent": None,
        },
        "cgroups": {},
    }


class FakeSlurm:
    def __init__(self):
        self.rows = {}
        self.released = []
        self.cancelled = []
        self.fail = False
        self.counter = 0

    def submit(self, job, directory):
        self.counter += 1
        identity = str(self.counter)
        self.rows[identity] = dict(job_id=int(identity), name="rs-" + job["id"], job_state=["PENDING"])
        return identity

    def jobs(self):
        if self.fail:
            raise OSError("offline")
        return list(self.rows.values())

    def detail(self, job_id):
        return self.rows[job_id]

    def release(self, job_id):
        self.released.append(job_id)
        self.rows[job_id]["job_state"] = ["RUNNING"]

    def cancel(self, job_id):
        self.cancelled.append(job_id)
        self.rows[job_id]["job_state"] = ["CANCELLED"]


class FakeHost:
    def __init__(self):
        self.started, self.stopped, self.forgotten = [], [], []
        self.units = {}

    def start(self, job, directory):
        self.started.append(job["id"])
        self.units[job["systemd_unit"]] = dict(
            LoadState="loaded",
            ActiveState="active",
            SubState="running",
            Result="success",
            ExecMainPID="123",
            ExecMainStatus="0",
            ExecMainCode="1",
        )

    def status(self, unit):
        return self.units.get(unit, {"LoadState": "not-found"})

    def stop(self, unit):
        self.stopped.append(unit)

    def forget(self, unit):
        self.forgotten.append(unit)


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.slurm = FakeSlurm()
        self.host = FakeHost()
        self.snapshot = snapshot()
        self.log = io.StringIO()
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(contextlib.redirect_stdout(self.log))
        self.backend = rs.Backend(
            dict(
                state_dir=self.temp.name,
                allowed_uid=os.getuid(),
                stability_seconds=0,
                history_limit=3,
                cgroup_root=str(Path(self.temp.name) / "cgroups"),
            ),
            self.slurm,
            lambda: copy.deepcopy(self.snapshot),
            host=self.host,
        )

    def tearDown(self):
        os.close(self.backend.lock_fd)
        self.stack.close()
        self.temp.cleanup()

    def request(
        self,
        cpu=2,
        ram=4096,
        vram=0,
        priority="background",
        mode="shared",
        origin="host",
        explore=False,
        profile=None,
        variant=None,
    ):
        return dict(
            version=1,
            action="submit",
            label="safe build",
            explore=explore,
            profile=profile,
            variant=variant,
            origin=origin,
            requested=dict(cpu=cpu, ram_mib=ram, vram_mib=vram),
            mode=mode,
            priority=priority,
            category="build",
            payload=dict(command=["echo", "secret-argument"], cwd="/tmp", env={"SECRET": "credential"}),
            agent="agent",
            worktree="worktree",
            project="project",
        )

    def submit(self, **kwargs):
        result = self.backend.handle(self.request(**kwargs), os.getuid())
        job = next(j for j in self.backend.state["jobs"] if j["id"] == result["id"])
        path = (
            Path(self.backend.config["cgroup_root"]) / "system.slice/slurmstepd.scope" / ("job_" + job["slurm_job_id"])
        )
        path.mkdir(parents=True, exist_ok=True)
        (path / "cpu.max").write_text("max 100000\n")
        (path / "cpu.weight").write_text("100\n")
        return job

    def control(self, action, job, **kwargs):
        return self.backend.handle(
            dict(version=1, action=action, id=job["id"], revision=job["revision"], confirm=True, **kwargs), os.getuid()
        )

    def profiled(self, **kwargs):
        return self.submit(
            origin="agent-sandbox-test", explore=True, profile="runtime", variant="scene-1080p-v1", **kwargs
        )

    def profile(self):
        return self.backend.handle(dict(version=1, action="profiles"), os.getuid())["profiles"][0]

    def finish(self, job, state="COMPLETED", code=0):
        self.slurm.rows[job["slurm_job_id"]].update(job_state=[state], exit_code={"return_code": code})
        self.backend.tick()

    def test_gpu_barrier_allows_cpu_work_but_preserves_gpu_order(self):
        active = self.submit(mode="exclusive", vram=5000, priority="game")
        self.backend.tick()
        first = self.submit(vram=2000, ram=1024)
        second = self.submit(vram=1000, ram=1024)
        cpu = self.submit(ram=1024)
        self.backend.tick()
        self.assertEqual(active["state"], "running")
        self.assertEqual(first["state"], "queued")
        self.assertIn("CPU-only jobs may pass", first["wait_reason"])
        self.assertIn(first["id"], second["wait_reason"])
        self.assertEqual(cpu["state"], "pending")
        self.assertEqual(cpu["events"][-1]["bypassed_job_ids"], [first["id"]])
        self.finish(active)
        self.assertEqual(first["state"], "pending")
        self.assertEqual(second["state"], "queued")

    def test_gpu_backfill_keeps_cpu_ram_pause_and_unknown_checks(self):
        active = self.submit(mode="exclusive", vram=5000, priority="game")
        self.backend.tick()
        self.submit(vram=1000, ram=1024)
        cpu = self.submit(cpu=5, ram=1024)
        self.backend.tick()
        self.assertEqual(cpu["state"], "queued")
        self.assertIn("CPU", cpu["wait_reason"])
        cpu["requested"]["cpu"] = 2
        self.backend.state["paused"] = True
        self.backend.tick()
        self.assertEqual(cpu["state"], "queued")
        self.backend.state["paused"] = False
        self.snapshot["ram"]["available_mib"] = 4200
        self.backend.tick()
        self.assertEqual(cpu["state"], "queued")
        self.snapshot["ram"]["available_mib"] = 20000
        self.slurm.rows[active["slurm_job_id"]]["job_state"] = ["MYSTERY"]
        self.backend.tick()
        self.assertEqual(cpu["state"], "queued")

    def test_exploration_requires_sandbox_profile_and_shared_non_game_mode(self):
        for changes in (
            {"origin": "host"},
            {"profile": None},
            {"variant": None},
            {"mode": "exclusive"},
            {"priority": "game"},
            {"explore": "yes"},
        ):
            request = self.request(origin="agent-sandbox-test", explore=True, profile="runtime", variant="v1")
            request.update(changes)
            with self.assertRaises(ValueError):
                self.backend.handle(request, os.getuid())
        self.assertFalse(self.slurm.rows)

    def test_cli_submits_exploration_and_preserves_output_exit_and_profile_lookup(self):
        calls = []
        identity = "a" * 32

        def rpc(request):
            calls.append(request)
            if request["action"] == "submit":
                return {"id": identity}
            return dict(
                stdout="",
                stderr="",
                stdout_offset=0,
                stderr_offset=0,
                job=dict(
                    state="failed",
                    exit_code=7,
                    profile={"project": "project", "name": "runtime", "variant": "v1"},
                    failure="command_failed",
                ),
            )

        argv = [
            "resource-scheduler",
            "run",
            "--explore",
            "--gpu",
            "--project",
            "project",
            "--profile",
            "runtime",
            "--variant",
            "v1",
            "--name",
            "probe",
            "--",
            "echo",
            "hello",
        ]
        with (
            patch.dict(os.environ, {"AGENT_SANDBOX_INSTANCE": "agent-sandbox-test"}, clear=True),
            patch.object(rs.sys, "argv", argv),
            patch.object(rs, "rpc", side_effect=rpc),
        ):
            self.assertEqual(rs.main(), 7)
        self.assertEqual(calls[0]["requested"], dict(cpu=2, ram_mib=4096, vram_mib=1024))
        self.assertEqual(calls[0]["mode"], "shared")
        self.assertEqual(calls[0]["payload"]["command"], ["echo", "hello"])
        self.assertEqual(calls[0]["variant"], "v1")
        self.assertTrue(calls[0]["explore"])
        self.assertEqual(len([c for c in calls if c["action"] == "submit"]), 1)
        with (
            patch.object(
                rs.sys,
                "argv",
                ["resource-scheduler", "profile", "--project", "project", "--profile", "runtime", "--variant", "v1"],
            ),
            patch.object(rs, "rpc", return_value={"profiles": []}) as lookup,
        ):
            self.assertEqual(rs.main(), 0)
            self.assertEqual(
                lookup.call_args.args[0], dict(action="profiles", project="project", profile="runtime", variant="v1")
            )

    def test_complete_gpu_inventory_distinguishes_idle_zero_from_missing(self):
        job = self.profiled(vram=1024)
        self.backend.tick()
        self.snapshot["gpu"].update(process_inventory_complete=True, attribution_confidence="cgroup-gpu-processes")
        self.backend.tick()
        self.assertEqual(job["observed"]["vram_mib"], 0)
        self.assertEqual(job["gpu_missing_samples"], 0)
        self.snapshot["gpu"]["allocations_mib"] = {job["slurm_job_id"]: 1500}
        self.backend.tick()
        self.finish(job)
        self.assertIsNotNone(self.profile()["recommendation"]["vram_mib"])

    def test_exploration_defaults_are_bounded_and_explicit_gpu_only(self):
        args = SimpleNamespace(
            cpu=None, ram=None, vram=None, explore=True, gpu=False, exclusive=False, priority="background"
        )
        self.assertEqual(rs.run_budgets(args), dict(cpu=2, ram_mib=4096, vram_mib=0))
        args.gpu = True
        self.assertEqual(rs.run_budgets(args)["vram_mib"], 1024)
        args.ram, args.vram = 8192, 2048
        self.assertEqual(rs.run_budgets(args), dict(cpu=2, ram_mib=8192, vram_mib=2048))
        args.explore = False
        with self.assertRaises(ValueError):
            rs.run_budgets(args)

    def test_exploration_slurm_allocation_stays_shared_and_time_limited(self):
        job = self.profiled(vram=1024)
        with patch.object(rs, "checked", return_value="99") as call:
            rs.Slurm(self.backend.config).submit(job, Path(self.temp.name))
        argv = call.call_args.args[0]
        self.assertIn("--time=00:30:00", argv)
        self.assertIn("--mem=4096M", argv)
        self.assertIn("--gres=shard:1024", argv)
        self.assertNotIn("--gres=gpu:1", argv)

    def test_gpu_exploration_blocks_following_gpu_launches_not_cpu(self):
        probe = self.profiled(vram=1024)
        self.backend.tick()
        gpu = self.submit(vram=1024, ram=1024)
        cpu = self.submit(ram=1024)
        self.backend.tick()
        self.assertEqual(probe["state"], "running")
        self.assertIn("exploration", gpu["wait_reason"])
        self.assertEqual(cpu["state"], "pending")

    def test_headroom_intervention_only_cancels_exploration(self):
        normal = self.submit(ram=1024)
        self.backend.tick()
        probe = self.profiled(vram=1024)
        self.backend.tick()
        self.backend.tick()
        self.snapshot["gpu"]["free_mib"] = 1000
        self.backend.tick()
        self.assertEqual(self.slurm.cancelled, [probe["slurm_job_id"]])
        self.assertEqual(normal["state"], "running")
        self.assertEqual(probe["cleanup"], "cancellation-requested")
        self.backend.tick()
        self.assertEqual(probe["failure"], "exploration_headroom")
        self.assertEqual(self.profile()["consecutive_probe_failures"], 1)
        self.assertIsNone(self.profile()["recommendation"]["vram_mib"])

    def test_profiles_retain_successful_peaks_and_survive_restart_and_history_pruning(self):
        probe = self.profiled(vram=1024)
        self.backend.tick()
        self.snapshot["gpu"].update(
            allocations_mib={probe["slurm_job_id"]: 4200}, attribution_confidence="cgroup-gpu-processes"
        )
        self.snapshot["cgroups"][probe["slurm_job_id"]] = {"memory.current": 3000, "memory.peak": 3500}
        self.backend.tick()
        self.backend.tick()
        self.finish(probe)
        record = self.profile()
        self.assertEqual(record["runs"], 1)
        self.assertEqual(record["ram_peak_mib"], 3500)
        self.assertEqual(record["vram_peak_mib"], 4200)
        self.assertEqual(record["recommendation"]["ram_mib"], 4608)
        self.assertEqual(record["recommendation"]["vram_mib"], 5376)
        self.backend.tick()
        self.assertEqual(self.profile()["runs"], 1)
        for _ in range(4):
            other = self.submit(ram=1024)
            self.finish(other)
        self.assertNotIn(probe, self.backend.state["jobs"])
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.assertEqual(self.profile()["runs"], 1)
        self.assertEqual(self.profile()["vram_peak_mib"], 4200)
        self.assertNotIn("secret-argument", json.dumps(self.profile()))
        self.assertNotIn("credential", json.dumps(self.profile()))

    def test_profile_recommendations_do_not_use_missing_or_single_gpu_sample(self):
        for samples, missing in ((0, 0), (1, 0), (2, 1)):
            probe = self.profiled(vram=1024)
            probe["gpu_samples"], probe["gpu_missing_samples"] = samples, missing
            probe["observed"].update(vram_peak_mib=1000, attribution_confidence="cgroup-gpu-processes")
            self.finish(probe)
            self.assertIsNone(self.profile()["recommendation"]["vram_mib"])
            self.assertIsNone(self.profile()["recommendation"]["ram_mib"])

    def test_profile_failure_evidence_and_retry_bound(self):
        for text, state, expected in (
            ("not enough disk space", "FAILED", "command_failed"),
            ("torch.OutOfMemoryError: CUDA out of memory", "FAILED", "gpu_oom_reported"),
            ("", "OUT_OF_MEMORY", "ram_oom"),
        ):
            job = self.profiled(vram=1024)
            (Path(self.temp.name) / job["id"] / "stderr").write_text(text)
            self.finish(job, state, 1)
            self.assertEqual(job["failure"], expected)
            self.assertIsNone(self.profile()["recommendation"]["ram_mib"])
        with self.assertRaisesRegex(ValueError, "Three exploration failures"):
            self.profiled(vram=1024)
        self.assertEqual(self.slurm.counter, 3)
        # An explicitly budgeted successful run can establish a corrected profile.
        explicit = self.submit(profile="runtime", variant="scene-1080p-v1", vram=4096)
        self.finish(explicit)
        self.assertEqual(self.profile()["consecutive_probe_failures"], 0)

    def test_profile_keys_separate_workload_settings_and_reject_duplicates(self):
        probe = self.profiled()
        with self.assertRaisesRegex(ValueError, "active work"):
            self.profiled()
        different = self.submit(explore=True, origin="agent-sandbox-test", profile="runtime", variant="scene-4k-v1")
        self.assertNotEqual(probe["profile"], different["profile"])
        with self.assertRaises(ValueError):
            self.submit(profile="bad\nname", variant="v1")
        response = self.backend.handle(
            dict(version=1, action="profiles", project="project", profile="runtime", variant="scene-4k-v1"), os.getuid()
        )
        self.assertEqual(len(response["profiles"]), 1)
        with self.assertRaises(PermissionError):
            self.backend.handle(dict(version=1, action="profiles"), os.getuid() + 1)

    def test_profile_storage_is_bounded_and_unmanaged_results_do_not_train_it(self):
        job = self.profiled()
        self.control("run-host", job)
        self.backend.tick()
        self.host.units[job["systemd_unit"]].update(ActiveState="active", SubState="exited")
        rs.atomic(Path(self.temp.name) / job["id"] / "result.json", {"exit_code": 0})
        self.backend.tick()
        self.assertEqual(self.profile()["runs"], 0)
        for i in range(127):
            identity = {"project": "project", "name": "extra", "variant": str(i)}
            self.backend.state["profiles"][json.dumps(identity, sort_keys=True)] = rs.new_profile(identity)
        with self.assertRaisesRegex(ValueError, "Profile limit"):
            self.submit(profile="new", variant="v1")

    def test_graphics_and_compute_memory_are_attributed_without_double_counting(self):
        proc = Path(self.temp.name) / "proc"
        for pid, group in (
            ("10", "0::/system.slice/slurmstepd.scope/job_42/step_batch"),
            ("11", "0::/system.slice/slurmstepd.scope/job_42/step_batch"),
            ("12", "0::/user.slice/desktop"),
        ):
            (proc / pid).mkdir(parents=True)
            (proc / pid / "cgroup").write_text(group)
        xml = (
            "<nvidia_smi_log><gpu><uuid>GPU-test</uuid><processes>"
            + "".join(
                f"<process_info><pid>{pid}</pid><type>{kind}</type><used_memory>{memory} MiB</used_memory></process_info>"
                for pid, kind, memory in ((10, "G", 3000), (11, "C+G", 1000), (12, "G", 200))
            )
            + "</processes></gpu></nvidia_smi_log>"
        )
        self.assertEqual(rs.gpu_process_allocations(xml, "GPU-test", proc), {"42": 4000})
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations(xml.replace("3000 MiB", "N/A"), "GPU-test", proc)
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations(xml, "GPU-other", proc)
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations("broken xml", "GPU-test", proc)

    def test_external_ram_shortage_allows_small_job_and_records_bypass(self):
        self.snapshot["ram"]["available_mib"] = 9000
        large = self.submit(ram=10000)
        small = self.submit(ram=1000)
        self.backend.tick()
        self.assertEqual(large["state"], "queued")
        self.assertIn("smaller jobs may pass", large["wait_reason"])
        self.assertEqual(small["state"], "pending")
        self.assertEqual(small["events"][-1]["bypassed_job_ids"], [large["id"]])

    def test_running_completion_preserves_barrier_when_it_can_supply_ram(self):
        active = self.submit(ram=5000)
        self.backend.tick()
        self.snapshot["cgroups"][active["slurm_job_id"]] = {"memory.current": 5000}
        self.snapshot["ram"]["available_mib"] = 9000
        large = self.submit(ram=9000)
        small = self.submit(ram=500)
        self.backend.tick()
        self.assertEqual(small["state"], "queued")
        self.assertIn(large["id"], small["wait_reason"])
        self.snapshot["cgroups"][active["slurm_job_id"]]["memory.current"] = 1000
        self.backend.tick()
        self.assertEqual(small["state"], "pending")

    def test_external_vram_and_missing_gpu_telemetry_allow_cpu_work(self):
        large = self.submit(vram=16000)
        small = self.submit(ram=1000)
        self.snapshot["gpu"]["free_mib"] = 8000
        self.backend.tick()
        self.assertIn("VRAM shortage", large["wait_reason"])
        self.assertEqual(small["state"], "pending")
        self.snapshot["gpu"]["free_mib"] = None
        self.backend.tick()
        self.assertIn("GPU telemetry unavailable", large["wait_reason"])

    def test_unknown_and_pending_allocations_never_allow_backfill(self):
        head = self.submit(ram=30000)
        active = self.submit(ram=1000)
        for state in ("unknown", "pending"):
            active["state"] = state
            self.assertIsNone(rs.external_block_reason(head, [head, active], self.snapshot, self.backend.config))
        active["state"] = "running"
        active["observed"]["ram_mib"] = None
        self.assertIsNone(rs.external_block_reason(head, [head, active], self.snapshot, self.backend.config))

    def test_backfill_respects_pause_and_pressure(self):
        self.submit(ram=30000)
        small = self.submit(ram=1000)
        self.backend.state["paused"] = True
        self.backend.tick()
        self.assertEqual(small["state"], "queued")
        self.backend.state["paused"] = False
        self.snapshot["pressure"]["memory"] = {"full": {"avg10": 2}}
        self.backend.tick()
        self.assertEqual(small["state"], "queued")

    def test_run_next_changes_order_but_keeps_admission_checks(self):
        first = self.submit()
        next_job = self.submit()
        self.control("run-next", next_job)
        self.assertFalse(self.slurm.released)
        self.backend.tick()
        self.assertEqual(self.slurm.released, [next_job["slurm_job_id"]])
        self.assertEqual(first["state"], "queued")

    def test_force_run_releases_now_without_weakening_requested_budget(self):
        self.submit(ram=30000)
        job = self.submit(ram=10000, mode="exclusive")
        budget = dict(job["requested"])
        self.backend.state["paused"] = True
        self.snapshot["ram"]["available_mib"] = 1
        self.control("force-run", job)
        self.assertEqual(job["state"], "pending")
        self.assertEqual(self.slurm.released, [job["slurm_job_id"]])
        self.assertEqual(job["requested"], budget)
        self.assertTrue(job["events"][-1]["forced"])
        self.backend.tick()
        self.assertEqual(job["state"], "running")

    def test_force_run_lost_reply_does_not_release_twice(self):
        job = self.submit()
        with patch.object(self.slurm, "release", side_effect=OSError("lost reply")) as release:
            with self.assertRaises(OSError):
                self.control("force-run", job)
            self.assertEqual(job["state"], "unknown")
            self.backend.tick()
            self.assertEqual(release.call_count, 1)
            with self.assertRaises(ValueError):
                self.control("force-run", job)

    def test_queue_controls_require_confirmation_revision_and_queued_identity(self):
        for action in ("force-run", "run-next", "run-host", "run-sandbox"):
            job = self.submit()
            for changes in ({"confirm": False}, {"revision": 0}):
                request = dict(version=1, action=action, id=job["id"], revision=job["revision"], confirm=True)
                request.update(changes)
                with self.assertRaises(ValueError):
                    self.backend.handle(request, os.getuid())
            self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["RUNNING"]
            with self.assertRaises(ValueError):
                self.control(action, job)
            self.slurm.rows[job["slurm_job_id"]]["name"] = "different-job"
            with self.assertRaises(ValueError):
                self.control(action, job)
        self.assertFalse(self.host.started)
        self.assertFalse(self.slurm.released)

    def test_sandbox_override_rejects_host_origin_without_cancelling(self):
        job = self.submit()
        with self.assertRaisesRegex(ValueError, "sandbox-origin"):
            self.control("run-sandbox", job)
        self.assertFalse(self.slurm.cancelled)
        self.assertFalse(self.host.started)
        self.assertTrue(rs.managed(job))

    def test_sandbox_handoff_preserves_identity_output_and_cleanup(self):
        job = self.submit(origin="agent-sandbox-test", vram=1000)
        self.control("run-sandbox", job)
        self.assertEqual(job["execution"], "sandbox")
        self.assertTrue(job["systemd_unit"].startswith("resource-sandbox-"))
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["COMPLETING"]
        self.backend.tick()
        self.assertFalse(self.host.started)
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["CANCELLED"]
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(self.host.started, [job["id"]])
        self.assertEqual(job["state"], "running")
        self.assertIsNone(self.backend.public_job(job)["allocation"])
        self.assertEqual(self.backend.public_telemetry()["ram"]["reserved_mib"], 0)
        self.assertEqual(self.backend.public_telemetry()["gpu"]["reserved_mib"], 0)
        directory = Path(self.temp.name) / job["id"]
        payload = json.loads((directory / "payload.json").read_text())
        self.assertEqual(payload["execution"], "sandbox")
        self.assertEqual(payload["origin"], "agent-sandbox-test")
        self.assertEqual(payload["command"], ["echo", "secret-argument"])
        (directory / "stdout").write_text("sandbox output")
        (directory / "stderr").write_text("sandbox diagnostic")
        rs.atomic(directory / "result.json", {"exit_code": 7})
        self.host.units[job["systemd_unit"]].update(
            ActiveState="failed", SubState="failed", Result="exit-code", ExecMainStatus="7"
        )
        self.slurm.fail = True
        self.backend.tick()
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["exit_code"], 7)
        self.assertEqual(job["cleanup"], "systemd-terminal")
        self.assertFalse((directory / "payload.json").exists())
        result = self.backend.handle(dict(version=1, action="output", id=job["id"]), os.getuid())
        self.assertEqual(result["stdout"], "sandbox output")
        self.assertEqual(result["stderr"], "sandbox diagnostic")
        self.assertEqual(job["events"][-1]["execution"], "sandbox")

    def test_sandbox_cancel_and_terminate_keep_descendant_cleanup(self):
        queued = self.submit(origin="agent-sandbox-test")
        self.control("run-sandbox", queued)
        self.control("cancel", queued)
        self.backend.tick()
        self.assertEqual(queued["state"], "cancelled")
        self.assertFalse(self.host.started)
        running = self.submit(origin="agent-sandbox-test")
        self.control("run-sandbox", running)
        self.backend.tick()
        self.control("terminate", running)
        self.assertEqual(self.host.stopped, [running["systemd_unit"]])
        self.assertEqual(running["state"], "running")
        self.host.units[running["systemd_unit"]].update(
            ActiveState="inactive", SubState="dead", Result="signal", ExecMainCode="2", ExecMainStatus="15"
        )
        self.backend.tick()
        self.assertEqual(running["state"], "cancelled")
        self.assertEqual(running["exit_code"], 143)

    def test_sandbox_lost_launch_reply_is_not_retried_after_restart(self):
        job = self.submit(origin="agent-sandbox-test")
        self.control("run-sandbox", job)
        with patch.object(self.host, "start", side_effect=OSError("lost")) as start:
            self.backend.tick()
            self.backend.tick()
            self.assertEqual(start.call_count, 1)
            self.assertEqual(job["state"], "unknown")
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.backend.tick()
        self.assertFalse(self.host.started)

    def test_sandbox_environment_preserves_sandbox_but_removes_reservations(self):
        payload = dict(
            id="a" * 32,
            execution="sandbox",
            origin="agent-sandbox-test",
            env={
                key: "stale"
                for key in (
                    "RESOURCE_JOB_ID",
                    "GPU_LEASE_ID",
                    "RESOURCE_CPU",
                    "RESOURCE_RAM_MIB",
                    "RESOURCE_VRAM_MIB",
                    "RESOURCE_CPUSET",
                    "RESOURCE_HOST_JOB_ID",
                    "AGENT_SANDBOX_INSTANCE",
                )
            }
            | {"ORCA_WORKTREE_ID": "real-card", "PATH": "/bin"},
        )
        env = rs.execution_environment(payload)
        self.assertEqual(
            env,
            {
                "AGENT_SANDBOX_INSTANCE": "agent-sandbox-test",
                "ORCA_WORKTREE_ID": "real-card",
                "PATH": "/bin",
                "RESOURCE_EXECUTION_MODE": "unmanaged-sandbox",
                "RESOURCE_SANDBOX_JOB_ID": payload["id"],
            },
        )

    def test_sandbox_bootstrap_requires_authorization_and_never_falls_back(self):
        job = self.submit(origin="agent-sandbox-test")
        directory = Path(self.temp.name) / job["id"]
        with patch.object(os, "getuid", return_value=0), patch.dict(os.environ, INVOCATION_ID="service"):
            with self.assertRaisesRegex(ValueError, "not authorized"):
                rs.step(directory, sandbox=True)
        self.control("run-sandbox", job)
        self.backend.tick()
        with patch.object(os, "getuid", return_value=0), patch.dict(os.environ, INVOCATION_ID="service"):
            with patch.object(rs, "namespace_command", side_effect=ValueError("sandbox unavailable")) as enter:
                with patch.object(rs.subprocess, "Popen") as launch:
                    with self.assertRaisesRegex(ValueError, "sandbox unavailable"):
                        rs.step(directory, sandbox=True)
                    self.assertEqual(enter.call_args.args[0]["origin"], "agent-sandbox-test")
                    launch.assert_not_called()

    def test_sandbox_bootstrap_streams_namespace_process_output_and_exit(self):
        job = self.submit(origin="agent-sandbox-test")
        self.control("run-sandbox", job)
        self.backend.tick()
        directory = Path(self.temp.name) / job["id"]
        command = [
            rs.sys.executable,
            "-c",
            "import sys; print('namespace stdout'); print('namespace stderr', file=sys.stderr); sys.exit(7)",
        ]
        with patch.object(os, "getuid", return_value=0), patch.dict(os.environ, INVOCATION_ID="service"):
            with patch.object(rs, "namespace_command", return_value=(command, [])) as enter:
                self.assertEqual(rs.step(directory, sandbox=True), 7)
                self.assertEqual(enter.call_args.args[0]["execution"], "sandbox")
        self.assertEqual((directory / "stdout").read_text(), "namespace stdout\n")
        self.assertEqual((directory / "stderr").read_text(), "namespace stderr\n")
        self.assertEqual(json.loads((directory / "result.json").read_text())["exit_code"], 7)

    def test_sandbox_service_uses_explicit_sandbox_bootstrap(self):
        job = {"id": "a" * 32, "execution": "sandbox", "systemd_unit": "resource-sandbox-" + "a" * 32 + ".service"}
        with patch.object(rs, "checked", return_value="") as call:
            rs.HostRunner().start(job, Path("/private/state") / job["id"])
        argv = call.call_args.args[0]
        self.assertIn("sandbox-step", argv)
        self.assertNotIn("host-step", argv)
        self.assertIn("--property=KillMode=control-group", argv)

    def test_host_handoff_confirms_slurm_cancellation_before_launch(self):
        job = self.submit(vram=1000)
        self.control("run-host", job)
        self.assertFalse(self.host.started)
        self.assertEqual(job["execution"], "host")
        self.assertEqual(self.backend.public_telemetry()["ram"]["reserved_mib"], 0)
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["COMPLETING"]
        self.backend.tick()
        self.assertFalse(self.host.started)
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["CANCELLED"]
        self.backend.tick()
        self.assertEqual(self.host.started, [job["id"]])
        self.assertEqual(job["state"], "running")
        self.assertIsNone(self.backend.public_job(job)["allocation"])
        payload = json.loads((Path(self.temp.name) / job["id"] / "payload.json").read_text())
        self.assertEqual(payload["execution"], "host")
        self.backend.tick()
        self.assertEqual(len(self.host.started), 1)

    def test_host_cancel_during_handoff_does_not_launch(self):
        job = self.submit()
        self.control("run-host", job)
        self.control("cancel", job)
        self.backend.tick()
        self.assertEqual(job["state"], "cancelled")
        self.assertFalse(self.host.started)

    def test_host_completion_retains_output_result_and_cleans_payload(self):
        job = self.submit()
        self.control("run-host", job)
        self.backend.tick()
        directory = Path(self.temp.name) / job["id"]
        (directory / "stdout").write_text("host output")
        rs.atomic(directory / "result.json", {"exit_code": 7})
        self.host.units[job["systemd_unit"]].update(
            ActiveState="failed", SubState="failed", Result="exit-code", ExecMainStatus="7"
        )
        self.slurm.fail = True
        self.backend.tick()
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["exit_code"], 7)
        self.assertEqual(job["cleanup"], "systemd-terminal")
        self.assertFalse((directory / "payload.json").exists())
        response = self.backend.handle(dict(version=1, action="output", id=job["id"]), os.getuid())
        self.assertEqual(response["stdout"], "host output")

    def test_host_termination_waits_for_systemd_cleanup(self):
        job = self.submit()
        self.control("run-host", job)
        self.backend.tick()
        self.control("terminate", job)
        self.assertEqual(self.host.stopped, [job["systemd_unit"]])
        self.assertEqual(job["state"], "running")
        self.host.units[job["systemd_unit"]].update(
            ActiveState="inactive", SubState="dead", Result="signal", ExecMainCode="2", ExecMainStatus="15"
        )
        self.backend.tick()
        self.assertEqual(job["state"], "cancelled")
        self.assertEqual(job["exit_code"], 143)

    def test_host_lost_start_reply_is_reconciled_without_relaunch(self):
        job = self.submit()
        self.control("run-host", job)
        with patch.object(self.host, "start", side_effect=OSError("lost")) as start:
            self.backend.tick()
            self.assertEqual(job["state"], "unknown")
            self.backend.tick()
            self.assertEqual(start.call_count, 1)
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.backend.tick()
        self.assertFalse(self.host.started)

    def test_unmanaged_environment_has_no_reservation_or_sandbox_markers(self):
        payload = dict(
            id="a" * 32,
            execution="host",
            env={
                "RESOURCE_JOB_ID": "old",
                "GPU_LEASE_ID": "old",
                "RESOURCE_RAM_MIB": "123",
                "AGENT_SANDBOX_INSTANCE": "sandbox",
                "ORCA_WORKTREE_ID": "real-card",
                "PATH": "/bin",
            },
        )
        env = rs.execution_environment(payload)
        self.assertEqual(env["RESOURCE_EXECUTION_MODE"], "unmanaged-host")
        self.assertEqual(env["RESOURCE_HOST_JOB_ID"], payload["id"])
        self.assertEqual(env["ORCA_WORKTREE_ID"], "real-card")
        for key in ("RESOURCE_JOB_ID", "GPU_LEASE_ID", "RESOURCE_RAM_MIB", "AGENT_SANDBOX_INSTANCE"):
            self.assertNotIn(key, env)

    def test_host_service_launch_uses_only_trusted_bootstrap_arguments(self):
        runner = rs.HostRunner()
        job = {"id": "a" * 32, "systemd_unit": "resource-host-" + "a" * 32 + ".service"}
        with patch.object(rs, "checked", return_value="") as call:
            runner.start(job, Path("/private/state") / job["id"])
        argv = call.call_args.args[0]
        self.assertEqual(argv[0], "systemd-run")
        self.assertIn("--property=KillMode=control-group", argv)
        self.assertIn("--property=RemainAfterExit=yes", argv)
        self.assertIn("host-step", argv)
        self.assertNotIn("secret-argument", " ".join(argv))
        self.assertNotIn("--user", argv)
        self.assertEqual(call.call_args.kwargs, {})

    def test_host_inactive_without_a_started_process_is_not_completion(self):
        job = self.submit()
        self.control("run-host", job)
        with patch.object(self.host, "start"):
            self.host.units[job["systemd_unit"]] = dict(
                LoadState="loaded",
                ActiveState="inactive",
                SubState="dead",
                Result="success",
                ExecMainPID="0",
                ExecMainCode="0",
                ExecMainStatus="0",
            )
            self.backend.tick()
        self.assertEqual(job["state"], "pending")
        self.assertTrue((Path(self.temp.name) / job["id"] / "payload.json").exists())

    def test_reordering_is_immediately_visible_and_latest_request_wins(self):
        first, second = self.submit(), self.submit()
        with patch.object(rs.time, "time", return_value=100):
            self.control("run-next", second)
        with patch.object(rs.time, "time", return_value=101):
            self.control("run-next", first)
        positions = {job["id"]: job["queue_position"] for job in self.backend.status()["jobs"]}
        self.assertEqual(positions[first["id"]], 1)
        self.assertEqual(positions[second["id"]], 2)

    def test_joint_reservations_and_no_small_job_overtaking(self):
        first = self.submit(ram=10000, vram=10000)
        second = self.submit(ram=10000, vram=10000)
        third = self.submit(ram=1000)
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(first["state"], "running")
        self.assertEqual(second["state"], "queued")
        self.assertIn("RAM", second["wait_reason"])
        self.assertIn(second["id"], third["wait_reason"])
        self.assertEqual(self.slurm.released, [first["slurm_job_id"]])

    def test_compatible_jobs_overlap(self):
        self.submit(vram=4000)
        second = self.submit(vram=4000)
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(second["state"], "pending")
        self.assertEqual(len(self.slurm.released), 2)

    def test_no_double_counting_actual_memory(self):
        job = self.submit(ram=10000)
        job["state"] = "running"
        job["observed"]["ram_mib"] = 9000
        candidate = self.request(ram=10000)
        self.assertIsNone(rs.admission_reason(candidate, [job], snapshot(ram=16000), self.backend.config))
        job["observed"]["ram_mib"] = None
        self.assertIn("RAM", rs.admission_reason(candidate, [job], snapshot(ram=16000), self.backend.config))

    def test_vram_unknown_attribution_gets_no_credit(self):
        job = self.submit(vram=10000)
        job["state"] = "running"
        candidate = self.request(vram=10000)
        self.assertIn("VRAM", rs.admission_reason(candidate, [job], snapshot(free=15000), self.backend.config))
        job["observed"]["vram_mib"] = 9000
        self.assertIsNone(rs.admission_reason(candidate, [job], snapshot(free=15000), self.backend.config))

    def test_gpu_failure_blocks_gpu_but_allows_cpu(self):
        self.snapshot = snapshot(free=None)
        self.submit()
        second = self.submit(vram=1000)
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(second["state"], "queued")
        self.assertIn("telemetry", second["wait_reason"])

    def test_exclusive_and_game_priority_does_not_preempt(self):
        active = self.submit(vram=4000)
        self.backend.tick()
        self.backend.tick()
        background = self.submit(vram=1000)
        game = self.submit(mode="exclusive", priority="game")
        self.backend.tick()
        self.assertEqual(game["state"], "queued")
        self.assertIn("shared", game["wait_reason"])
        self.assertIn(game["id"], background["wait_reason"])
        self.assertEqual(active["state"], "running")

    def test_pressure_hold_requires_stability(self):
        job = self.submit()
        self.snapshot["pressure"]["memory"] = {"full": {"avg10": 2}}
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.assertIn("Pressure", job["wait_reason"])
        self.snapshot["pressure"]["memory"] = {"full": {"avg10": 0}}
        self.backend.config["stability_seconds"] = 20
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.backend.healthy_since -= 21
        self.backend.tick()
        self.assertEqual(job["state"], "pending")

    def test_control_authorization_confirmation_and_revision(self):
        job = self.submit()
        with self.assertRaises(PermissionError):
            self.backend.handle(dict(version=1, action="status"), os.getuid() + 1)
        for revision, confirm in ((job["revision"] + 1, True), (job["revision"], False)):
            with self.assertRaises(ValueError):
                self.backend.handle(
                    dict(version=1, action="cancel", id=job["id"], revision=revision, confirm=confirm), os.getuid()
                )
        self.control("cancel", job)
        self.assertEqual(job["cleanup"], "cancellation-requested")
        self.assertNotIn(job["state"], rs.TERMINAL)
        self.backend.tick()
        self.assertEqual(job["state"], "cancelled")
        self.assertEqual(job["cleanup"], "slurm-terminal")

    def test_running_cancel_requires_explicit_terminate(self):
        job = self.submit()
        self.backend.tick()
        self.backend.tick()
        with self.assertRaises(ValueError):
            self.control("cancel", job)
        self.control("terminate", job)
        self.assertEqual(self.slurm.cancelled, [job["slurm_job_id"]])

    def test_restart_recovers_slurm_identity_without_releasing_unknown(self):
        job = self.submit()
        job["slurm_job_id"] = None
        self.backend.save()
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot))
        self.backend.tick()
        recovered = self.backend.state["jobs"][0]
        self.assertEqual(recovered["slurm_job_id"], "1")
        self.assertEqual(recovered["state"], "pending")
        self.slurm.rows.clear()
        self.backend.tick()
        self.assertEqual(recovered["state"], "unknown")
        candidate = self.submit()
        self.backend.tick()
        self.assertIn("unknown", candidate["wait_reason"])

    def test_slurm_offline_blocks_release(self):
        job = self.submit()
        self.slurm.fail = True
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.assertTrue(self.backend.status()["errors"])
        self.assertFalse(self.slurm.released)

    def test_completed_result_exit_and_peak_summary(self):
        job = self.submit()
        self.backend.tick()
        self.backend.tick()
        rs.atomic(Path(self.temp.name) / job["id"] / "result.json", dict(exit_code=7, observed=dict(ram_peak_mib=123)))
        self.slurm.rows["1"]["job_state"] = ["COMPLETED"]
        self.backend.tick()
        self.assertEqual(job["exit_code"], 7)
        self.assertEqual(job["observed"]["ram_peak_mib"], 123)
        self.assertFalse((Path(self.temp.name) / job["id"] / "payload.json").exists())
        self.assertEqual(self.backend.status()["history"][0]["id"], job["id"])

    def test_bounded_history_events_and_secret_exclusion(self):
        for _ in range(5):
            job = self.submit()
            self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["COMPLETED"]
            self.backend.tick()
        status = self.backend.status()
        self.assertEqual(len(status["history"]), 3)
        self.assertEqual(len(list(Path(self.temp.name).glob("*/payload.json"))), 0)
        output = json.dumps(status) + self.log.getvalue()
        for secret in ("secret-argument", "credential", "SECRET"):
            self.assertNotIn(secret, output)
        for _ in range(80):
            self.backend.event(job, "model-loaded")
        self.assertEqual(len(job["events"]), 64)

    def test_pause_is_admission_only(self):
        job = self.submit()
        self.backend.handle(dict(version=1, action="pause", confirm=True), os.getuid())
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.assertFalse(self.slurm.cancelled)
        self.backend.handle(dict(version=1, action="resume", confirm=True), os.getuid())
        self.backend.tick()
        self.assertEqual(job["state"], "pending")

    def test_invalid_budgets_and_nested_requests(self):
        for update in (
            dict(requested=dict(cpu=99, ram_mib=1, vram_mib=0)),
            dict(nested=True),
            dict(requested=dict(cpu=True, ram_mib=1, vram_mib=0)),
            dict(priority="game"),
            dict(origin="../../escape"),
        ):
            with self.assertRaises(ValueError):
                self.backend.handle({**self.request(), **update}, os.getuid())

    def test_submitted_slurm_resources_are_atomic_held_and_private(self):
        job = self.submit(vram=1000)
        with patch.object(rs, "checked", return_value="123;cluster\n") as command:
            identity = rs.Slurm(self.backend.config).submit(job, Path(self.temp.name) / job["id"])
        self.assertEqual(identity, "123")
        argv = command.call_args.args[0]
        for value in ("--hold", "--cpus-per-task=2", "--mem=4096M", "--gres=shard:1000", "--export=NONE"):
            self.assertIn(value, argv)
        self.assertNotIn("secret-argument", str(command.call_args))
        self.assertNotIn("credential", str(command.call_args))

    def test_socket_framing_malformed_oversize_and_version(self):
        for data in (b"[]\n", b"{\n", b'{"x":NaN}\n', b"{}\n{}\n", b"x" * (rs.MAX_MESSAGE + 1)):
            left, right = socket.socketpair()
            with left, right:
                # send in a background producer to avoid filling the Unix socket buffer.
                import threading

                producer = threading.Thread(target=lambda: (right.sendall(data), right.shutdown(socket.SHUT_WR)))
                producer.start()
                try:
                    with self.assertRaises((ValueError, json.JSONDecodeError)):
                        rs.read_message(left)
                finally:
                    producer.join(timeout=2)
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=99, action="status"), os.getuid())

    def test_status_contract_unknown_metrics_stay_null(self):
        self.backend.tick()
        value = self.backend.status()
        self.assertEqual(value["schema_version"], 1)
        self.assertIsNone(value["telemetry"]["cpu"]["host_actual"])
        self.assertEqual(value["telemetry"]["cpu"]["actual"], 0)
        self.assertFalse(value["capabilities"]["unload"])
        self.assertGreater(value["revision"], 0)
        json.dumps(value, allow_nan=False)

    def test_legacy_guard_does_not_delete_records(self):
        # Real lock semantics covered independently without changing another running scheduler.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lease.json"
            path.write_text("{}")
            import fcntl

            with path.open() as owner, path.open() as observer:
                fcntl.flock(owner, fcntl.LOCK_EX)
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(observer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(path.exists())

    def test_namespace_bridge_rejects_wrong_user_and_mutable_store(self):
        payload = dict(origin="agent-sandbox-test", uid=1000, gid=100)
        for data in (
            [dict(Name="/agent-sandbox-test", State=dict(Running=True), Config=dict(User="0:0"), Mounts=[])],
            [
                dict(
                    Name="/agent-sandbox-test",
                    State=dict(Running=True),
                    Config=dict(User="1000:100"),
                    Mounts=[dict(Destination="/nix/store", Source="/nix/store", RW=True)],
                )
            ],
        ):
            with patch.object(rs, "checked", return_value=json.dumps(data)):
                with self.assertRaises(ValueError):
                    rs.namespace_command(payload, 5)

    def test_exclusive_nonzero_desktop_usage_and_explicit_peak(self):
        self.snapshot = snapshot(free=20000)
        job = self.submit(mode="exclusive", vram=15000)
        self.backend.tick()
        self.assertEqual(job["state"], "pending")
        self.assertEqual(job["requested"]["vram_mib"], 15000)
        self.assertEqual(self.backend.status()["jobs"][0]["requested"]["vram_mib"], 15000)

    def test_exclusive_unknown_budget_freezes_at_admission_and_survives_restart(self):
        self.snapshot = snapshot(free=20000)
        self.submit(mode="exclusive")
        self.backend.tick()
        effective = 20000 - self.backend.config["vram_headroom_mib"]
        public = self.backend.status()["jobs"][0]
        self.assertIsNone(public["requested"]["vram_mib"])
        self.assertEqual(public["allocation"]["vram_mib"], effective)
        self.assertEqual(public["vram_estimate"], "all-available")
        self.snapshot = snapshot(free=6000)
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot))
        self.backend.tick()
        self.assertEqual(self.backend.state["jobs"][0]["requested"]["vram_mib"], effective)

    def test_explicit_exclusive_peak_waits_for_external_usage(self):
        self.snapshot = snapshot(free=20000)
        job = self.submit(mode="exclusive", vram=18000)
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.assertIn("VRAM", job["wait_reason"])
        self.snapshot = snapshot(free=25000)
        self.backend.tick()
        self.assertEqual(job["state"], "pending")

    def test_game_quotas_apply_and_restore_without_reducing_game_budget(self):
        background = self.submit(cpu=8)
        self.backend.tick()
        self.backend.tick()
        marker = Path(self.temp.name) / "game-active"
        self.backend.config["game_marker_path"] = str(marker)
        marker.touch()
        self.backend.tick()
        path = Path(self.backend.config["cgroup_root"]) / "system.slice/slurmstepd.scope/job_1"
        self.assertEqual((path / "cpu.max").read_text().strip(), "400000 100000")
        self.assertEqual((path / "cpu.weight").read_text().strip(), "25")
        marker.unlink()
        game = self.submit(cpu=4, mode="exclusive", priority="game")
        self.backend.tick()
        self.assertEqual(game["state"], "pending")
        self.assertEqual(background["state"], "running")
        self.slurm.rows[game["slurm_job_id"]]["job_state"] = ["COMPLETED"]
        self.backend.tick()
        self.assertEqual((path / "cpu.max").read_text().strip(), "max 100000")
        self.assertEqual((path / "cpu.weight").read_text().strip(), "100")

    def test_game_cpu_failure_is_explicit_and_holds_admission(self):
        self.submit(cpu=8)
        self.backend.tick()
        self.backend.tick()
        path = Path(self.backend.config["cgroup_root"]) / "system.slice/slurmstepd.scope/job_1/cpu.max"
        path.unlink()
        game = self.submit(mode="exclusive", priority="game")
        self.backend.tick()
        self.assertEqual(game["state"], "queued")
        self.assertTrue(self.backend.status()["telemetry"]["cpu"]["game_protection_errors"])

    def test_native_slurm_optional_exit_scalar_wrappers(self):
        self.assertEqual(
            rs.slurm_exit(dict(return_code=dict(set=True, number=7), signal=dict(id=dict(set=True, number=0)))), 7
        )
        self.assertEqual(rs.slurm_exit(dict(return_code=0, signal=dict(id=dict(set=True, number=15)))), 143)
        self.assertIsNone(rs.slurm_exit(dict(return_code=dict(set=False, number=0))))

    def test_wire_status_bound_preserves_all_active_jobs(self):
        job = self.submit()
        self.backend.tick()
        seed = copy.deepcopy(job)
        self.backend.state["jobs"] = []
        for index in range(256 + 500):
            item = copy.deepcopy(seed)
            item["id"] = f"{index:032x}"
            for field in ("label", "agent", "worktree", "project"):
                item[field] = "😀" * 40
            item["state"] = "queued" if index < 256 else "completed"
            item["events"] = [
                dict(event="waiting", timestamp=1, reason="x" * 5000, snapshot={"value": "x" * 5000}) for _ in range(64)
            ]
            self.backend.state["jobs"].append(item)
        value = self.backend.status()
        self.assertEqual(len(value["jobs"]), 256)
        self.assertLess(len(json.dumps(value, ensure_ascii=False).encode()), 900001)
        self.assertTrue(value["truncated"]["events"])

    def test_model_events_reported_duration_do_not_claim_unload_support(self):
        job = self.submit(vram=1000)
        self.backend.tick()
        self.backend.tick()
        for state in ("loading", "ready", "busy", "idle", "unloaded"):
            value = self.backend.handle(
                dict(version=1, action="model-event", id=job["id"], state=state, model_label="local model"), os.getuid()
            )
        self.assertEqual(value["model"]["state"], "unloaded")
        self.assertGreaterEqual(value["model"]["load_seconds"], 0)
        self.assertEqual(value["model"]["attribution_confidence"], "owner-reported")
        self.assertFalse(self.backend.status()["capabilities"]["unload"])
        with self.assertRaises(ValueError):
            self.backend.handle(
                dict(version=1, action="model-event", id=job["id"], state="busy", model_label="different model"),
                os.getuid(),
            )

    def test_journal_unknown_peak_is_distinct_from_allocation(self):
        job = self.submit(mode="exclusive")
        self.backend.tick()
        event = next(e for e in job["events"] if e["event"] == "admission")
        self.assertIsNone(event["requested"]["vram_mib"])
        self.assertEqual(event["vram_estimate"], "all-available")
        self.assertEqual(event["allocation"]["vram_mib"], job["requested"]["vram_mib"])

    def test_interactive_priority_aging_protects_large_background(self):
        background = self.submit(ram=10000)
        interactive = self.submit(ram=1000, priority="interactive")
        self.backend.tick()
        self.assertEqual(interactive["state"], "pending")
        self.slurm.rows[interactive["slurm_job_id"]]["job_state"] = ["COMPLETED"]
        background["created_at"] -= 61
        newer = self.submit(priority="interactive")
        self.backend.tick()
        self.assertEqual(newer["state"], "queued")
        self.assertEqual(background["state"], "pending")

    def test_external_game_mode_blocks_gpu_admission_even_when_vram_fits(self):
        marker = Path(self.temp.name) / "external-game"
        marker.touch()
        self.backend.config["game_marker_path"] = str(marker)
        job = self.submit(vram=1000)
        self.backend.tick()
        self.assertEqual(job["state"], "queued")
        self.assertIn("External GameMode", job["wait_reason"])

    def test_native_id_reuse_is_not_controlled_or_claimed(self):
        job = self.submit()
        self.slurm.rows[job["slurm_job_id"]]["name"] = "rs-" + "a" * 32
        with self.assertRaises(ValueError):
            self.control("cancel", job)
        self.assertFalse(self.slurm.cancelled)
        self.backend.tick()
        self.assertEqual(job["state"], "unknown")
        self.assertIn("identity mismatch", job["wait_reason"])

    def test_definitive_submission_rejection_reconciles_without_leaking_reservations(self):
        with patch.object(self.slurm, "submit", side_effect=subprocess.CalledProcessError(1, ["sbatch"])):
            with self.assertRaises(RuntimeError):
                self.backend.handle(self.request(), os.getuid())
        self.backend.tick()
        job = self.backend.state["jobs"][0]
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["cleanup"], "slurm-rejected-no-allocation")
        self.assertFalse((Path(self.temp.name) / job["id"] / "payload.json").exists())
        self.assertEqual(self.backend.status()["telemetry"]["ram"]["reserved_mib"], 0)

    def test_legacy_compatibility_parses_options_after_operation(self):
        with patch.object(rs, "run", return_value=7) as run:
            self.assertEqual(rs.compat(["run", "--vram", "1GiB", "--name", "safe", "--", "echo", "hello"]), 7)
            args = run.call_args.args[0]
            self.assertEqual((args.cpu, args.ram, args.vram), (1, 4096, 1024))
            self.assertEqual(args.command, ["--", "echo", "hello"])
        with patch.object(rs, "run", return_value=0) as run:
            rs.compat(["game", "--name", "game", "--", "true"])
            self.assertEqual(run.call_args.args[0].priority, "game")
            self.assertTrue(run.call_args.args[0].exclusive)

    def test_cpu_host_actual_requires_two_kernel_counter_samples(self):
        self.snapshot["cpu"] = dict(total_ticks=1000, busy_ticks=500, logical_cpus=32, host_actual=None)
        self.backend.tick()
        self.assertIsNone(self.backend.status()["telemetry"]["cpu"]["host_actual"])
        self.snapshot["cpu"].update(total_ticks=2000, busy_ticks=750)
        self.backend.tick()
        value = self.backend.status()["telemetry"]["cpu"]
        self.assertEqual(value["logical_cpus"], 32)
        self.assertEqual(value["host_actual"], 8)
        self.assertEqual(value["external"], 8)

    def test_unknown_resource_metadata_does_not_enter_public_or_journal(self):
        request = self.request()
        request["requested"]["private"] = "credential" * 1000
        self.backend.handle(request, os.getuid())
        self.assertNotIn("credential", json.dumps(self.backend.status()) + self.log.getvalue())
        for value in ([], None, 1):
            with self.assertRaises(ValueError):
                self.backend.handle({**self.request(), "requested": value}, os.getuid())

    def test_unicode_label_byte_bound(self):
        self.assertEqual(rs.clean_label("😀" * 40), "😀" * 40)
        with self.assertRaises(ValueError):
            rs.clean_label("😀" * 41)

    def test_client_prefers_actual_orca_agent_session_identity(self):
        args = SimpleNamespace(
            cpu=1,
            ram=64,
            vram=None,
            exclusive=False,
            priority="background",
            category="build",
            project=None,
            name="safe",
            command=["true"],
        )
        response = dict(
            stdout="", stderr="", stdout_offset=0, stderr_offset=0, job=dict(state="completed", exit_code=7)
        )
        with patch.dict(
            os.environ, {"ORCA_AGENT_SESSION_ID": "actual-session", "ORCA_SESSION_ID": "legacy-session"}, clear=True
        ):
            with patch.object(rs, "rpc", side_effect=[dict(id="a" * 32), response]) as rpc:
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(rs.run(args), 7)
                self.assertEqual(rpc.call_args_list[0].args[0]["agent"], "actual-session")


if __name__ == "__main__":
    unittest.main()
