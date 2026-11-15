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


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.slurm = FakeSlurm()
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
        )

    def tearDown(self):
        os.close(self.backend.lock_fd)
        self.stack.close()
        self.temp.cleanup()

    def request(self, cpu=2, ram=4096, vram=0, priority="background", mode="shared"):
        return dict(
            version=1,
            action="submit",
            label="safe build",
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
        background = self.submit(ram=18000)
        interactive = self.submit(ram=1000, priority="interactive")
        self.backend.tick()
        self.assertEqual(interactive["state"], "pending")
        self.slurm.rows[interactive["slurm_job_id"]]["job_state"] = ["COMPLETED"]
        background["created_at"] -= 61
        newer = self.submit(priority="interactive")
        self.backend.tick()
        self.assertEqual(newer["state"], "queued")
        self.assertIn(background["id"], newer["wait_reason"])

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
