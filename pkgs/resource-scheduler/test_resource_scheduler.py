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

    def hold(self, job_id):
        if self.rows[job_id]["job_state"] != ["PENDING"]:
            raise OSError("already allocated")
        self.rows[job_id]["priority"] = 0

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
        return self.backend.handle(
            dict(version=1, action="profiles", project="project", profile="runtime", variant="scene-1080p-v1"),
            os.getuid(),
        )["profiles"][0]

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
        self.backend.handle(dict(version=1, action="notification-ack", id=probe["id"], confirm=True), os.getuid())
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
        identity = "a" * 32
        (proc / "10" / "cgroup").write_text(f"0::/system.slice/resource-large-{identity}.service/child")
        (proc / "12" / "cgroup").write_text(f"0::/user.slice/resource-large-{identity}.service")
        self.assertEqual(rs.gpu_process_allocations(xml, "GPU-test", proc), {identity: 3000, "42": 1000})
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations(xml.replace("3000 MiB", "N/A"), "GPU-test", proc)
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations(xml, "GPU-other", proc)
        with self.assertRaises(ValueError):
            rs.gpu_process_allocations("broken xml", "GPU-test", proc)

    def test_inspect_and_output_are_read_only_private_payload_is_never_exposed(self):
        job = self.submit()
        job["waiter_token"] = "b" * 32
        directory = Path(self.temp.name) / job["id"]
        (directory / "stdout").write_text("first output")
        revision = self.backend.state["revision"]
        result = self.backend.handle(dict(version=1, action="inspect", id=job["id"]), os.getuid())
        self.assertEqual(result["output"]["stdout"]["bytes"], 12)
        self.assertEqual(self.backend.state["revision"], revision)
        for value in ("secret-argument", "credential", "b" * 32):
            self.assertNotIn(value, json.dumps(result))
        output = self.backend.handle(dict(version=1, action="output", id=job["id"], stdout_offset=6), os.getuid())
        self.assertEqual(output["stdout"], "output")
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=1, action="output", id=job["id"], stdout_offset=-1), os.getuid())
        with self.assertRaises(PermissionError):
            self.backend.handle(dict(version=1, action="inspect", id=job["id"]), os.getuid() + 1)

    def test_notification_waiter_heartbeat_ack_and_claim_are_persisted(self):
        job = self.submit()
        token = "b" * 32
        self.backend.handle(dict(version=1, action="watch", id=job["id"], token=token), os.getuid())
        self.finish(job, "FAILED", 7)
        self.assertEqual(job["notification"]["state"], "pending")
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=1, action="notification-claim", id=job["id"]), os.getuid())
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=1, action="notification-ack", id=job["id"]), os.getuid())
        self.backend.handle(dict(version=1, action="notification-ack", id=job["id"], token=token), os.getuid())
        self.assertEqual(job["notification"]["state"], "pending")
        self.assertIn("output_consumed_at", job)
        with patch.object(rs.time, "time", return_value=job["ended_at"] + 11):
            self.assertTrue(self.backend.notification_inbox()[0]["ready"])
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.assertEqual(len(self.backend.notification_inbox()), 1)
        self.backend.handle(dict(version=1, action="notification-ack", id=job["id"], confirm=True), os.getuid())
        self.assertEqual(self.backend.notification_inbox(), [])

    def test_expired_waiter_claim_survives_restart_without_duplicate_delivery(self):
        job = self.submit()
        self.finish(job)
        with patch.object(rs.time, "time", return_value=job["ended_at"] + 31):
            claim = self.backend.handle(dict(version=1, action="notification-claim", id=job["id"]), os.getuid())
        self.assertEqual(job["notification"]["state"], "sending")
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=1, action="notification-claim", id=job["id"]), os.getuid())
        with self.assertRaises(ValueError):
            self.backend.handle(
                dict(version=1, action="notification-finish", id=job["id"], token="wrong", state="delivered"),
                os.getuid(),
            )
        self.backend.handle(
            dict(version=1, action="notification-finish", id=job["id"], token=claim["token"], state="delivered"),
            os.getuid(),
        )
        self.assertEqual(self.backend.notification_inbox()[0]["notification"]["state"], "delivered")

    def test_state_notifications_coalesce_and_reject_stale_claims(self):
        job = self.submit()
        self.backend.changed(job, "running")
        running = job["notification"]["generation"]
        self.backend.changed(job, "unknown")
        self.backend.changed(job, "queued")
        self.assertEqual(len(self.backend.notification_inbox()), 1)
        self.assertEqual(job["notification"]["job_state"], "queued")
        with patch.object(rs.time, "time", return_value=job["notification"]["created_at"] + 11):
            with self.assertRaises(ValueError):
                self.backend.handle(dict(version=1, action="notification-claim", id=job["id"], generation=running), os.getuid())
            claim = self.backend.handle(dict(version=1, action="notification-claim", id=job["id"], generation=job["notification"]["generation"]), os.getuid())
        self.finish(job)
        with self.assertRaises(ValueError):
            self.backend.handle(dict(version=1, action="notification-finish", id=job["id"], token=claim["token"], state="delivered"), os.getuid())
        self.assertEqual(job["notification"]["state"], "pending")
        self.assertEqual(job["notification"]["job_state"], "completed")

    def test_slurm_start_notifies_despite_active_waiter(self):
        job = self.submit()
        self.backend.handle(dict(version=1, action="watch", id=job["id"], token="b" * 32), os.getuid())
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["RUNNING"]
        self.backend.tick()
        self.assertEqual(job["notification"]["job_state"], "running")
        generation = job["notification"]["generation"]
        self.backend.tick()
        self.assertEqual(job["notification"]["generation"], generation)
        with patch.object(rs.time, "time", return_value=job["notification"]["created_at"] + 11):
            self.assertTrue(self.backend.notification_inbox()[0]["ready"])

    def test_unreviewed_completion_pins_output_until_acknowledged(self):
        first = self.submit()
        self.finish(first)
        directory = Path(self.temp.name) / first["id"]
        (directory / "stderr").write_text("diagnostic")
        for _ in range(4):
            self.finish(self.submit())
        self.assertTrue(directory.exists())
        self.backend.handle(dict(version=1, action="notification-ack", id=first["id"], confirm=True), os.getuid())
        self.backend.tick()
        self.assertFalse(directory.exists())

    def test_resource_job_logs_streams_bounded_chunks_and_wait_returns_actual_exit(self):
        job = self.submit()
        directory = Path(self.temp.name) / job["id"]
        (directory / "stdout").write_text("x" * 40000)
        self.finish(job, "FAILED", 7)
        args = SimpleNamespace(
            operation="logs",
            id=job["id"],
            json=False,
            follow=False,
            stream="stdout",
            stdout_offset=0,
            stderr_offset=0,
            timeout=None,
        )
        output = io.StringIO()
        with (
            patch.object(
                rs, "rpc", side_effect=lambda request: self.backend.handle({"version": 1, **request}, os.getuid())
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(rs.resource_job(args), 0)
            self.assertEqual(len(output.getvalue()), 40000)
            args.operation = "wait"
            self.assertEqual(rs.resource_job(args), 7)
        self.assertEqual(job["notification"]["state"], "pending")
        self.assertIn("output_consumed_at", job)

    def test_resource_job_wait_timeout_does_not_cancel_or_resubmit(self):
        job = self.submit()
        args = SimpleNamespace(
            operation="wait",
            id=job["id"],
            json=False,
            follow=False,
            stream="both",
            stdout_offset=0,
            stderr_offset=0,
            timeout=1,
        )
        with (
            patch.object(
                rs, "rpc", side_effect=lambda request: self.backend.handle({"version": 1, **request}, os.getuid())
            ),
            patch.object(rs.time, "monotonic", side_effect=[0, 2]),
        ):
            self.assertEqual(rs.resource_job(args), 124)
        self.assertEqual(job["state"], "queued")
        self.assertEqual(self.slurm.cancelled, [])

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
            self.backend.handle(dict(version=1, action="notification-ack", id=job["id"], confirm=True), os.getuid())
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

    def test_large_gpu_lane_releases_around_normal_pressure_and_preserves_single_slot(self):
        self.backend.config.update(adaptive_ram=True, large_gpu_lane=True)
        self.snapshot["ram"]["available_mib"] = 2048
        self.snapshot["gpu"]["free_mib"] = 2048
        self.snapshot["pressure"]["memory"] = dict(full=dict(avg10=2), some=dict(avg10=10))
        normal = self.submit(ram=4096)
        first = self.submit(ram=16384, mode="exclusive")
        second = self.submit(ram=16384, vram=20000)
        self.snapshot["sampled_at"] = rs.time.time()
        self.backend.tick()
        self.assertEqual(normal["state"], "queued")
        self.assertEqual(first["state"], "pending")
        self.assertEqual(second["state"], "queued")
        self.assertGreater(first["requested"]["vram_mib"], 0)
        self.assertEqual(first["execution"], "large")
        self.assertEqual(first["events"][-1]["event"], "large_lane_handoff")
        self.snapshot["sampled_at"] = rs.time.time()
        self.backend.tick()
        self.assertEqual(first["state"], "running")
        self.assertIn("occupied", second["wait_reason"])
        self.backend.state["paused"] = True
        self.host.units[first["systemd_unit"]].update(ActiveState="active", SubState="exited")
        self.backend.tick()
        self.assertEqual(first["state"], "completed")
        self.assertEqual(second["state"], "queued")
        self.assertIn("paused", second["wait_reason"])

    def large_ready(self):
        self.backend.config.update(adaptive_ram=True, large_gpu_lane=True)
        self.snapshot["sampled_at"] = rs.time.time()
        self.snapshot["pressure"]["memory"] = dict(full=dict(avg10=0), some=dict(avg10=0))
        return self.submit(ram=16384, vram=24576, origin="agent-sandbox-test")

    def test_numeric_project_exception_shares_one_slot_with_all_large_jobs(self):
        self.backend.config["large_gpu_lane"] = True
        first = self.submit(ram=12288)
        second = self.profiled(ram=16384, vram=26000)
        second["project"] = "another-project"
        self.backend.config.update(
            large_gpu_lane=True, large_lane_project_ids=[rs.lane_project_id(first), rs.lane_project_id(second)]
        )
        self.snapshot["sampled_at"] = rs.time.time()
        self.snapshot["pressure"]["memory"] = dict(full=dict(avg10=0), some=dict(avg10=0))
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(first["execution"], "large")
        self.assertEqual(first["state"], "running")
        self.assertEqual(first["requested"]["vram_mib"], 0)
        first["observed"]["vram_mib"] = 300
        self.assertEqual(self.backend.status()["telemetry"]["gpu"]["managed_actual_mib"], 300)
        self.assertEqual(second["state"], "queued")
        self.assertIn("occupied", second["wait_reason"])
        self.host.units[first["systemd_unit"]].update(ActiveState="active", SubState="exited")
        self.backend.tick()
        self.backend.tick()
        self.assertEqual(second["execution"], "large")
        self.assertTrue(second["explore"])
        self.assertEqual(second["state"], "running")
        with patch.object(rs, "checked") as checked:
            rs.HostRunner().start(second, Path(self.temp.name) / second["id"])
        self.assertIn("--property=RuntimeMaxSec=1800", checked.call_args.args[0])
        before = list(self.slurm.cancelled)
        self.snapshot["ram"]["available_mib"] = 500
        self.backend.tick()
        self.assertEqual(self.host.stopped, [second["systemd_unit"]])
        self.assertEqual(self.slurm.cancelled, before)

    def test_numeric_project_identity_is_stable_and_strict_is_an_opt_out(self):
        job = self.submit()
        identity = rs.lane_project_id(job)
        self.assertTrue(identity.isdecimal())
        self.assertEqual(identity, rs.lane_project_id({**job, "worktree": "another-card"}))
        self.assertNotEqual(identity, rs.lane_project_id({**job, "project": "another-project"}))
        self.assertIsNone(rs.lane_project_id({}))
        self.backend.config.update(large_gpu_lane=True, large_lane_project_ids=[identity])
        job["memory_policy"] = "adaptive"
        self.assertTrue(rs.large_gpu_job(job, self.backend.config))
        job["memory_policy"] = "strict"
        self.assertFalse(rs.large_gpu_job(job, self.backend.config))
        self.assertEqual(self.backend.public_job(job)["lane_project_id"], identity)
        for invalid in ([1], ["not-numeric"], ["01"], "123", ["1" * 40]):
            with self.assertRaises(ValueError):
                rs.validate_config({**self.backend.config, "large_lane_project_ids": invalid})

    def test_large_handoff_waits_for_cancellation_and_rechecks_pressure(self):
        job = self.large_ready()
        with patch.object(self.slurm, "cancel"):
            self.backend.tick()
            self.backend.tick()
        self.assertEqual(self.host.started, [])
        self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["CANCELLED"]
        self.snapshot["ram"]["available_mib"] = 500
        self.backend.tick()
        self.assertIn("Critical", job["wait_reason"])
        self.assertEqual(self.host.started, [])
        self.snapshot["ram"]["available_mib"] = 2048
        self.backend.tick()
        self.assertEqual(self.host.started, [job["id"]])
        payload = json.loads((Path(self.temp.name) / job["id"] / "payload.json").read_text())
        self.assertEqual(payload["origin"], "agent-sandbox-test")
        self.assertEqual(payload["execution"], "large")
        self.backend.tick()
        self.assertEqual(self.host.started, [job["id"]])

    def test_large_handoff_does_not_cancel_job_that_started_during_hold(self):
        job = self.large_ready()

        def started(_):
            self.slurm.rows[job["slurm_job_id"]]["job_state"] = ["RUNNING"]

        with patch.object(self.slurm, "hold", side_effect=started):
            self.backend.tick()
        self.assertEqual(self.slurm.cancelled, [])
        self.assertEqual(self.host.started, [])
        self.assertTrue(rs.slurm_managed(job))

    def test_policy_five_pending_large_allocation_migrates_without_command_resubmission(self):
        job = self.large_ready()
        job.update(released=True, state="pending")
        self.backend.tick()
        self.assertEqual(job["execution"], "large")
        self.backend.tick()
        self.assertEqual(job["state"], "running")
        self.assertEqual(self.slurm.counter, 1)
        self.assertEqual(self.slurm.released, [])
        self.assertEqual(self.host.started, [job["id"]])

    def test_large_cancel_before_launch_and_terminate_after_launch(self):
        job = self.large_ready()
        self.backend.tick()
        self.control("cancel", job)
        self.backend.tick()
        self.assertEqual(job["state"], "cancelled")
        self.assertEqual(self.host.started, [])
        job = self.large_ready()
        self.backend.tick()
        self.backend.tick()
        self.control("terminate", job)
        self.assertEqual(self.host.stopped, [job["systemd_unit"]])

    def test_explicit_force_slurm_pending_is_not_migrated(self):
        job = self.large_ready()
        with patch.object(self.slurm, "release"):
            self.control("force-run", job)
        self.backend.tick()
        self.assertTrue(rs.slurm_managed(job))
        self.assertEqual(job["state"], "pending")
        self.assertEqual(self.slurm.cancelled, [])

    def test_large_handoff_accepts_slurm_optional_integer_priority(self):
        job = self.large_ready()

        def hold(identity):
            self.slurm.rows[identity]["priority"] = dict(set=True, infinite=False, number=0)

        with patch.object(self.slurm, "hold", side_effect=hold):
            self.backend.tick()
        self.assertEqual(job["execution"], "large")
        for value in (None, False, dict(set=False, number=0), dict(set=True, infinite=True, number=0)):
            self.assertFalse(rs.slurm_held(dict(job_state=["PENDING"], priority=value)))

    def test_collected_cancelled_service_releases_lane_without_relaunch(self):
        job = self.large_ready()
        self.backend.tick()
        self.backend.tick()
        self.control("terminate", job)
        gone = dict(LoadState="not-found", ActiveState="inactive", SubState="dead", ExecMainPID="0")
        self.host.units[job["systemd_unit"]] = gone
        successor = self.large_ready()
        self.backend.tick()
        self.assertEqual(job["state"], "cancelled")
        self.assertIsNone(job["exit_code"])
        self.assertEqual(job["cleanup"], "systemd-unit-and-cgroup-removed")
        self.assertEqual(successor["execution"], "large")
        self.assertEqual(self.host.started, [job["id"]])
        self.assertFalse((Path(self.temp.name) / job["id"] / "payload.json").exists())

    def test_missing_service_requires_cancel_intent_and_confirmed_cgroup_removal(self):
        job = self.large_ready()
        self.backend.tick()
        self.backend.tick()
        gone = dict(LoadState="not-found", ActiveState="inactive", SubState="dead", ExecMainPID="0")
        self.assertFalse(self.backend.cancelled_service_gone(job, gone))
        self.control("terminate", job)
        group = Path(self.backend.config["cgroup_root"]) / "system.slice" / job["systemd_unit"]
        group.mkdir()
        self.assertFalse(self.backend.cancelled_service_gone(job, gone))
        group.rmdir()
        self.assertTrue(self.backend.cancelled_service_gone(job, gone))
        for field, value in (("ActiveState", "active"), ("ExecMainPID", "123"), ("SubState", None)):
            self.assertFalse(self.backend.cancelled_service_gone(job, {**gone, field: value}))
        with patch.object(rs.Path, "stat", side_effect=PermissionError("unreadable")):
            with self.assertRaises(PermissionError):
                self.backend.cancelled_service_gone(job, gone)
        job["host_phase"] = "starting"
        self.assertFalse(self.backend.cancelled_service_gone(job, gone))

    def test_large_ambiguous_start_is_never_retried_after_restart(self):
        job = self.large_ready()
        self.backend.tick()
        with patch.object(self.host, "start", side_effect=OSError("ambiguous RPC")) as start:
            self.backend.tick()
            self.assertEqual(start.call_count, 1)
        self.assertEqual(job["state"], "unknown")
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.backend.tick()
        self.assertEqual(self.host.started, [])
        self.assertEqual(self.backend.state["jobs"][0]["state"], "unknown")

    def test_large_namespace_failure_never_launches_on_host(self):
        job = self.large_ready()
        path = Path(self.temp.name) / job["id"]
        payload = json.loads((path / "payload.json").read_text())
        payload["execution"] = "large"
        rs.atomic(path / "payload.json", payload)
        with (
            patch.object(rs.os, "getuid", return_value=0),
            patch.dict(rs.os.environ, {"INVOCATION_ID": "test"}),
            patch.object(rs, "namespace_command", side_effect=ValueError("sandbox missing")),
            patch.object(rs.subprocess, "Popen") as launch,
        ):
            with self.assertRaisesRegex(ValueError, "sandbox missing"):
                rs.step(path, large=True)
            launch.assert_not_called()

    def test_large_unit_has_hard_limits_and_managed_environment(self):
        job = self.large_ready()
        job.update(execution="large", systemd_unit="resource-large-" + job["id"] + ".service")
        with patch.object(rs, "checked") as checked:
            rs.HostRunner().start(job, Path(self.temp.name) / job["id"])
        argv = checked.call_args.args[0]
        for option in (
            "--property=CPUQuota=200%",
            "--property=MemoryMax=16384M",
            "--property=MemorySwapMax=0",
            "--property=OOMPolicy=kill",
            "large-step",
        ):
            self.assertIn(option, argv)
        payload = json.loads((Path(self.temp.name) / job["id"] / "payload.json").read_text())
        payload["execution"] = "large"
        env = rs.execution_environment(payload)
        self.assertEqual(env["RESOURCE_JOB_ID"], job["id"])
        self.assertEqual(env["RESOURCE_EXECUTION_MODE"], "managed-large")
        self.assertNotIn("RESOURCE_HOST_JOB_ID", env)

    def test_large_telemetry_and_oom_remain_managed(self):
        job = self.large_ready()
        self.backend.tick()
        self.snapshot["cgroups"][job["id"]] = {"memory.current": 700, "memory.peak": 1000, "oom_kill": 0}
        self.snapshot["gpu"].update(allocations_mib={job["id"]: 2500}, process_inventory_complete=True)
        self.backend.tick()
        self.assertEqual(job["observed"]["ram_mib"], 700)
        self.assertEqual(job["observed"]["vram_mib"], 2500)
        self.assertEqual(self.backend.status()["telemetry"]["ram"]["reserved_mib"], 16384)
        self.host.units[job["systemd_unit"]].update(
            ActiveState="failed", SubState="failed", Result="oom-kill", ExecMainStatus="9", ExecMainCode="2"
        )
        self.backend.tick()
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["failure"], "ram_oom")
        self.assertEqual(job["exit_code"], 137)

    def test_new_oom_blocks_adaptive_allowance_before_next_admission(self):
        first = self.submit(ram=3072)
        self.backend.tick()
        sibling = self.submit(ram=3072)
        self.backend.tick()
        candidate = self.submit(ram=2048)
        self.slurm.rows[first["slurm_job_id"]].update(job_state=["FAILED"], exit_code={"return_code": 137})
        first["observed"]["oom_kill"] = 1
        sibling.update(
            memory_policy="adaptive", ram_observed_since=960, ram_samples=[[960, 1024], [980, 1024], [998, 1024]]
        )
        self.snapshot["cgroups"][sibling["slurm_job_id"]] = {"memory.current": 1024, "memory.peak": 1024, "oom_kill": 0}
        self.snapshot["ram"]["available_mib"] = 7680
        self.snapshot["pressure"]["memory"] = dict(full=dict(avg10=0), some=dict(avg10=0))
        self.snapshot["sampled_at"] = 1000
        self.backend.config["adaptive_ram"] = True
        self.backend.healthy_since = 900
        with patch.object(rs.time, "time", return_value=1000):
            self.backend.tick()
        self.assertTrue(sibling["ram_learning_blocked"])
        self.assertEqual(candidate["state"], "queued")
        self.assertIn("Insufficient RAM", candidate["wait_reason"])

    def test_missing_cgroup_peak_resets_adaptive_startup_and_preserves_oom(self):
        job = self.submit()
        self.backend.tick()
        job.update(memory_policy="adaptive", ram_observed_since=1, ram_samples=[[1, 100], [2, 100], [3, 100]])
        job["observed"].update(oom_kill=1, ram_peak_mib=100)
        self.snapshot["cgroups"][job["slurm_job_id"]] = {"memory.current": 100}
        self.backend.tick()
        self.assertEqual(job["observed"]["oom_kill"], 1)
        self.assertEqual(job["ram_samples"], [])
        self.assertEqual(job["ram_admission"]["basis"], "strict/startup/unknown")

    def test_automatic_profiles_persist_private_identity_and_bound_storage(self):
        job = self.submit()
        self.assertTrue(job["profile_automatic"])
        self.assertNotIn("secret-argument", json.dumps(job["profile"]))
        identity = job["profile"]
        salt = self.backend.state["profile_salt"]
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: copy.deepcopy(self.snapshot), host=self.host)
        self.assertEqual(self.backend.state["profile_salt"], salt)
        self.assertEqual(self.submit()["profile"], identity)
        self.assertNotIn(salt, json.dumps(self.backend.status()))
        profiles = self.backend.state["profiles"]
        for i in range(127):
            profiles[str(i)] = {**rs.new_profile(dict(project="x", name="x", variant=str(i))), "automatic": True}
        req = self.request()
        req["payload"]["command"] = ["different-command"]
        self.backend.handle(req, os.getuid())
        self.assertEqual(len(profiles), 128)
        self.assertIn(json.dumps(identity, sort_keys=True), profiles)

    def test_ram_learning_uses_complete_successes_and_oom_disables_it(self):
        for peak in (1000, 1200, 1100):
            job = self.submit()
            job["observed"]["ram_peak_mib"] = peak
            job["ram_good_samples"] = 3
            self.finish(job)
        record = self.backend.state["profiles"][json.dumps(job["profile"], sort_keys=True)]
        self.assertEqual([r["peak"] for r in record["ram_runs"]], [1000, 1200, 1100])
        job = self.submit()
        job["observed"]["oom_kill"] = 1
        self.finish(job, "FAILED", 137)
        self.assertTrue(record["ram_learning_blocked"])
        self.assertEqual(len(record["ram_runs"]), 3)
        for _ in range(3):
            job = self.submit()
            job["observed"]["ram_peak_mib"] = 1400
            job["ram_good_samples"] = 3
            self.finish(job)
        self.assertFalse(record["ram_learning_blocked"])
        job = self.submit()
        job["observed"]["ram_peak_mib"] = 100
        job["ram_good_samples"] = 3
        job["ram_missing_samples"] = 1
        self.finish(job)
        self.assertEqual(len(record["ram_runs"]), 6)

    def test_optional_ownership_names_survive_history_and_restart(self):
        request = self.request()
        names = dict(repo="riso-scene-workflow", worktree_name="Vue app", parent_worktree_name="UI migration")
        request.update(names)
        result = self.backend.handle(request, os.getuid())
        job = next(j for j in self.backend.state["jobs"] if j["id"] == result["id"])
        self.finish(job)
        os.close(self.backend.lock_fd)
        self.backend = rs.Backend(self.backend.config, self.slurm, lambda: self.snapshot)
        inspected = self.backend.handle(dict(version=1, action="inspect", id=job["id"]), os.getuid())["job"]
        self.assertEqual({k: inspected[k] for k in names}, names)
        self.assertEqual(inspected["worktree"], "worktree")

    def test_ownership_names_are_optional_and_bounded(self):
        job = self.submit()
        for field in ("repo", "worktree_name", "parent_worktree_name"):
            self.assertIsNone(job[field])
            for invalid in ("x" * 161, "bad\nname", {"name": "bad"}):
                request = self.request()
                request[field] = invalid
                with self.assertRaises(ValueError):
                    self.backend.handle(request, os.getuid())

    def test_cli_declares_ownership_without_changing_project_or_command(self):
        argv = [
            "resource-scheduler",
            "run",
            "--cpu",
            "1",
            "--ram",
            "64MiB",
            "--name",
            "check",
            "--project",
            "stable-profile-key",
            "--repo",
            "Repo name",
            "--worktree",
            "repo::/child",
            "--worktree-name",
            "Child",
            "--parent-worktree-name",
            "Parent",
            "--",
            "true",
        ]
        response = dict(
            stdout="", stderr="", stdout_offset=0, stderr_offset=0, job=dict(state="completed", exit_code=0)
        )
        with patch.object(rs.sys, "argv", argv), patch.dict(os.environ, {}, clear=True):
            with patch.object(rs, "rpc", side_effect=[dict(id="a" * 32), response]) as rpc:
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(rs.main(), 0)
                submitted = rpc.call_args_list[0].args[0]
                self.assertEqual(submitted["repo"], "Repo name")
                self.assertEqual(submitted["worktree"], "repo::/child")
                self.assertEqual(submitted["worktree_name"], "Child")
                self.assertEqual(submitted["parent_worktree_name"], "Parent")
                self.assertEqual(submitted["project"], "stable-profile-key")
                self.assertEqual(submitted["payload"]["command"], ["true"])

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
