import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from gpu_scheduler import Scheduler, admission_reason, memory_size, gpu_snapshot, host_gpu_snapshot, validate_snapshot


SCRIPT = str(Path(__file__).with_name("gpu_scheduler.py"))


class AdmissionTests(unittest.TestCase):
    def job(self, name, mode="shared", vram=4096, state="waiting", game=False, order=1):
        return dict(id=name, label=name, mode=mode, vram_mib=vram, state=state, game=game, created_ns=order)

    def test_shared_reservations_account_for_grants_not_yet_allocated(self):
        active = self.job("first", vram=20000, state="running")
        second = self.job("second", vram=10000)
        self.assertIn("insufficient", admission_reason(second, [active, second], (32768, 1000), 4096))
        second["vram_mib"] = 4096
        self.assertIsNone(admission_reason(second, [active, second], (32768, 1000), 4096))

    def test_unmanaged_memory_is_counted(self):
        job = self.job("new", vram=8000)
        self.assertIn("insufficient", admission_reason(job, [job], (32768, 26000), 4096))

    def test_unallocated_grant_cannot_overlap_unmanaged_memory(self):
        active = self.job("first", vram=4096, state="running")
        second = self.job("second", vram=4096)
        self.assertIn("insufficient", admission_reason(second, [active, second], (32768, 26000), 4096))

    def test_loaded_model_is_counted_once_with_inference_capacity_reserved(self):
        active = self.job("model", vram=24 * 1024, state="running")
        small = self.job("small", vram=2 * 1024)
        allocations = {"model": 20 * 1024}
        self.assertIsNone(admission_reason(small, [active, small], (32768, 21 * 1024), 4096, allocations))
        # Five GiB physically fits beside the weights, but consumes reserved inference memory.
        small["vram_mib"] = 5 * 1024
        self.assertIn("insufficient", admission_reason(small, [active, small], (32768, 21 * 1024), 4096, allocations))

    def test_over_budget_usage_and_unmanaged_memory_still_count(self):
        active = self.job("model", vram=20 * 1024, state="running")
        small = self.job("small", vram=4 * 1024)
        self.assertIn("insufficient", admission_reason(
            small, [active, small], (32768, 27 * 1024), 4096, {"model": 26 * 1024}))
        self.assertIn("insufficient", admission_reason(
            small, [active, small], (32768, 29 * 1024), 4096, {"model": 20 * 1024}))

    def test_unknown_leases_do_not_credit_unmanaged_memory(self):
        active = self.job("model", vram=4096, state="running")
        small = self.job("small", vram=4096)
        self.assertIn("insufficient", admission_reason(
            small, [active, small], (32768, 26000), 4096, {"retired": 20000}))

    def test_exclusive_waits_for_leases_and_resident_memory(self):
        exclusive = self.job("video", mode="exclusive")
        active = self.job("small", state="running")
        self.assertIn("active shared", admission_reason(exclusive, [active, exclusive], (32768, 1000), 4096))
        self.assertIn("still in use", admission_reason(exclusive, [exclusive], (32768, 8000), 4096))
        self.assertIsNone(admission_reason(exclusive, [exclusive], (32768, 1000), 4096))

    def test_game_prevents_new_model_admissions(self):
        model = self.job("model", order=1)
        game = self.job("game", mode="exclusive", game=True, order=2)
        self.assertIn("behind game", admission_reason(model, [model, game], (32768, 1000), 4096))
        self.assertIsNone(admission_reason(game, [model, game], (32768, 1000), 4096))

    def test_fifo_exclusive_is_not_starved_by_small_jobs(self):
        exclusive = self.job("video", mode="exclusive", order=1)
        small = self.job("small", order=2)
        self.assertIn("behind video", admission_reason(small, [exclusive, small], (32768, 1000), 4096))

    def test_oversized_job_is_rejected(self):
        job = self.job("huge", vram=32000)
        with self.assertRaises(ValueError):
            admission_reason(job, [job], (32768, 1000), 4096)

    def test_memory_units(self):
        self.assertEqual(memory_size("1.5GiB"), 1536)
        self.assertEqual(memory_size("1MiB"), 1)


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.directory = self.root / "leases"
        self.memory = self.root / "memory"
        self.memory.write_text("32768, 1000\n")
        self.compute = self.root / "compute"
        self.compute.write_text("")
        probe = self.root / "nvidia-smi"
        probe.write_text(
            f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\n"
            f"if any('query-compute-apps' in arg for arg in sys.argv):\n    print(Path({str(self.compute)!r}).read_text())\n"
            f"else:\n    print(('GPU-test, ' if any('query-gpu=uuid' in arg for arg in sys.argv) else '') + Path({str(self.memory)!r}).read_text())\n"
        )
        probe.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "GPU_SCHEDULER_DIR": str(self.directory),
        }
        self.env.pop("GPU_LEASE_ID", None)
        self.env.pop("AGENT_SANDBOX_INSTANCE", None)
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

    def start(self, name, *options, code=None, action="run"):
        code = code or "import time; time.sleep(30)"
        process = subprocess.Popen(
            [sys.executable, SCRIPT, action, "--name", name, *options, "--", sys.executable, "-c", code],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.processes.append(process)
        return process

    def jobs(self):
        result = subprocess.run(
            [sys.executable, SCRIPT, "status", "--json"],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)["jobs"]

    def wait_for(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            jobs = self.jobs()
            if predicate(jobs):
                return jobs
            time.sleep(0.05)
        self.fail(f"Timed out waiting for expected leases: {jobs}")

    def start_telemetry(self):
        self.directory.mkdir(exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(str(self.directory / 'telemetry.sock'))
        listener.listen(16)
        bootstrap = (
            "import os, sys; "
            f"os.dup2({listener.fileno()}, 3); os.set_inheritable(3, True); "
            "os.environ['LISTEN_PID'] = str(os.getpid()); os.environ['LISTEN_FDS'] = '1'; "
            "os.execv(sys.executable, [sys.executable, sys.argv[1], 'serve-telemetry'])"
        )
        process = subprocess.Popen(
            [sys.executable, '-c', bootstrap, SCRIPT], env=self.env,
            pass_fds=(listener.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.processes.append(process)
        return process

    def test_host_attribution_allows_loaded_models_to_share_across_clients(self):
        self.start_telemetry()
        marker = self.root / "worker-pid"
        self.start("large", "--vram", "24GiB", code=(
            f"import os, time; from pathlib import Path; Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)"
        ))
        self.wait_for(lambda jobs: marker.exists())
        self.memory.write_text("32768, 21504\n")
        self.compute.write_text(f"GPU-test, {marker.read_text()}, 20480\n")
        self.start("small", "--vram", "2GiB")
        jobs = self.wait_for(lambda jobs: len(jobs) == 2 and all(j['state'] == 'running' for j in jobs))
        self.assertEqual(next(j for j in jobs if j['label'] == 'large')['allocated_mib'], 20480)

    def test_unreadable_host_process_and_missing_metrics_get_no_credit(self):
        self.start_telemetry()
        self.memory.write_text("32768, 26000\n")
        self.compute.write_text("GPU-test, 999999999, 20000\nGPU-other, 1, 20000\nGPU-test, 1, [N/A]\n")
        blocked = self.start("blocked", "--vram", "8GiB", "--timeout", "0.1")
        _, error = blocked.communicate(timeout=5)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn('insufficient', error)

    def test_invalid_attribution_falls_back_to_aggregate_usage(self):
        self.start_telemetry()
        self.compute.write_text("malformed telemetry\n")
        scheduler = Scheduler(self.directory)
        self.addCleanup(os.close, scheduler.mutex)
        with patch.dict(os.environ, self.env):
            self.assertEqual(gpu_snapshot(scheduler), ((32768, 1000), None))

    def test_concurrent_shared_jobs_and_exclusive_barrier(self):
        one = self.start("one", "--vram", "4GiB")
        self.wait_for(lambda jobs: any(j["label"] == "one" and j["state"] == "running" for j in jobs))
        two = self.start("two", "--vram", "4GiB")
        self.wait_for(lambda jobs: len(jobs) == 2 and all(j["state"] == "running" for j in jobs))
        exclusive = self.start("video", "--exclusive")
        self.wait_for(lambda jobs: any(j["label"] == "video" and j["state"] == "waiting" for j in jobs))
        later = self.start("later", "--vram", "1GiB")
        self.wait_for(lambda jobs: len(jobs) == 4)
        one.terminate()
        two.terminate()
        one.wait(timeout=5)
        two.wait(timeout=5)
        jobs = self.wait_for(lambda jobs: any(j["label"] == "video" and j["state"] == "running" for j in jobs))
        self.assertEqual(next(j for j in jobs if j["label"] == "later")["state"], "waiting")
        exclusive.terminate()
        exclusive.wait(timeout=5)
        self.wait_for(lambda jobs: len(jobs) == 1 and jobs[0]["state"] == "running")
        later.terminate()
        later.wait(timeout=5)
        self.assertEqual(self.jobs(), [])

    def test_queued_game_has_priority_and_cancellation_unblocks_queue(self):
        active = self.start("active", "--exclusive")
        self.wait_for(lambda jobs: jobs and jobs[0]["state"] == "running")
        self.start("video", "--exclusive")
        self.wait_for(lambda jobs: len(jobs) == 2)
        game = self.start("game", action="game")
        self.wait_for(lambda jobs: len(jobs) == 3)
        active.terminate()
        active.wait(timeout=5)
        jobs = self.wait_for(lambda jobs: any(j["label"] == "game" and j["state"] == "running" for j in jobs))
        self.assertEqual(next(j for j in jobs if j["label"] == "video")["state"], "waiting")
        game.terminate()
        game.wait(timeout=5)
        self.wait_for(lambda jobs: len(jobs) == 1 and jobs[0]["label"] == "video" and jobs[0]["state"] == "running")

    def test_dead_waiter_is_reaped(self):
        self.start("active", "--exclusive")
        self.wait_for(lambda jobs: jobs and jobs[0]["state"] == "running")
        waiter = self.start("cancelled", "--exclusive")
        self.wait_for(lambda jobs: len(jobs) == 2)
        waiter.kill()
        waiter.wait(timeout=5)
        self.assertEqual([job["label"] for job in self.jobs()], ["active"])

    def test_missing_telemetry_fails_closed_and_times_out(self):
        self.memory.write_text("not available")
        marker = self.root / "started"
        process = self.start("blocked", "--exclusive", "--timeout", "0.1", code=f"open({str(marker)!r}, 'w').close()")
        _, error = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("telemetry unavailable", error)
        self.assertFalse(marker.exists())
        self.assertEqual(self.jobs(), [])

    def test_exit_status_and_signal_are_preserved(self):
        process = self.start("exit", "--exclusive", code="raise SystemExit(7)")
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 7)
        process = self.start("signal", "--exclusive")
        self.wait_for(lambda jobs: any(j["label"] == "signal" and j["state"] == "running" for j in jobs))
        process.terminate()
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM)

    def test_detached_worker_keeps_reservation_after_launcher_exits(self):
        ready = self.root / "ready"
        release = self.root / "release"
        child = (
            "import time\nfrom pathlib import Path\n"
            f"Path({str(ready)!r}).touch()\n"
            f"while not Path({str(release)!r}).exists():\n    time.sleep(0.05)\n"
        )
        self.addCleanup(release.touch)
        parent = f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {child!r}], start_new_session=True)"
        process = self.start("detached", "--exclusive", code=parent)
        self.wait_for(lambda jobs: ready.exists())
        self.assertIsNone(process.poll())
        self.assertEqual(self.jobs()[0]["state"], "running")
        release.touch()
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(self.jobs(), [])

    def test_sandbox_without_shared_mount_fails_closed(self):
        with patch.dict(os.environ, {"AGENT_SANDBOX_INSTANCE": ""}):
            with self.assertRaisesRegex(RuntimeError, "not mounted"):
                Scheduler(self.root / "missing")


class TelemetryTests(unittest.TestCase):
    def test_invalid_snapshots_cannot_credit_unobserved_memory(self):
        for allocations in [{"a" * 32: 1001}, {"a" * 32: -1}, {"invalid": 1}]:
            with self.subTest(allocations=allocations), self.assertRaises(ValueError):
                validate_snapshot(dict(total_mib=32768, used_mib=1000, allocations_mib=allocations))

    def test_multiple_workers_aggregate_once_and_other_gpus_are_ignored(self):
        lease = 'a' * 32
        processes = f"GPU-test, 123, 4096\nGPU-test, 456, 2048\nGPU-test, 123, 4096\nGPU-other, 123, 9999\n"
        from io import BytesIO
        with patch('gpu_scheduler.subprocess.run', side_effect=[
            subprocess.CompletedProcess([], 0, processes),
            subprocess.CompletedProcess([], 0, 'GPU-test, 32768, 8000\n'),
        ]), patch('gpu_scheduler.Path.stat') as stat, patch('gpu_scheduler.Path.open') as opened:
            stat.return_value.st_uid = os.getuid()
            opened.side_effect = lambda *args: BytesIO(f'GPU_LEASE_ID={lease}\0'.encode())
            self.assertEqual(host_gpu_snapshot()['allocations_mib'], {lease: 6144})


if __name__ == "__main__":
    unittest.main()
