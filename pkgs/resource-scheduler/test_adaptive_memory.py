import copy
import json
import unittest
from unittest.mock import patch

import resource_scheduler as rs


class AdaptiveMemoryTests(unittest.TestCase):
    def setUp(self):
        self.config = {**rs.DEFAULTS, "adaptive_ram": True}
        self.now = 1000
        self.job = dict(
            state="running",
            mode="shared",
            priority="background",
            memory_policy="adaptive",
            requested=dict(cpu=3, ram_mib=3072, vram_mib=0),
            observed=dict(ram_mib=800, ram_peak_mib=1400),
            ram_observed_since=960,
            ram_samples=[[960, 800], [980, 800], [1000, 800]],
        )
        self.candidate = dict(
            state="queued", mode="shared", priority="background", requested=dict(cpu=3, ram_mib=4096, vram_mib=0)
        )
        self.snapshot = dict(
            sampled_at=1000, ram=dict(available_mib=14604), pressure=dict(memory=dict(full=dict(avg10=0)))
        )

    def test_riso_like_snapshot_admits_without_changing_limits(self):
        jobs = [copy.deepcopy(self.job) for _ in range(3)]
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIsNone(rs.admission_reason(self.candidate, jobs, self.snapshot, self.config))
            strict = {**self.config, "adaptive_ram": False}
            self.assertIn("Insufficient RAM", rs.admission_reason(self.candidate, jobs, self.snapshot, strict))
        self.assertTrue(all(j["requested"]["ram_mib"] == 3072 for j in jobs))

    def test_strict_startup_missing_and_stale_usage_retain_full_growth(self):
        for changes in [
            dict(memory_policy="strict"),
            dict(state="pending"),
            dict(ram_samples=[]),
            dict(ram_observed_since=995),
            dict(ram_learning_blocked=True),
            dict(observed=dict(ram_mib=None, ram_peak_mib=1400)),
        ]:
            job = {**self.job, **changes}
            allowance, basis = rs.ram_allowance(job, self.config, self.now)
            self.assertEqual(allowance, 3072 - (job["observed"]["ram_mib"] or 0))
            self.assertNotEqual(basis, "adaptive")
        self.assertEqual(rs.ram_allowance(self.job, self.config, 1020)[0], 2272)

    def test_short_poll_window_does_not_forget_completed_startup(self):
        self.job["ram_samples"] = [[999, 800], [999.5, 800], [1000, 800]]
        self.assertEqual(rs.ram_allowance(self.job, self.config, 1000)[1], "adaptive")

    def test_observed_peak_history_and_growth_protect_late_phases(self):
        self.job["learned_ram_peak_mib"] = 2800
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now)[0], 2272)
        self.job.pop("learned_ram_peak_mib")
        self.job["ram_samples"] = [[960, 100], [998, 100], [1000, 800]]
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now)[0], 2272)
        self.job["observed"]["ram_peak_mib"] = 3000
        self.job["observed"]["ram_mib"] = 100
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now)[0], 2972)

    def test_load_spike_stops_inflating_growth_once_it_leaves_the_recent_window(self):
        self.job["requested"]["ram_mib"] = 8192
        self.job["observed"] = dict(ram_mib=991, ram_peak_mib=2210)
        self.job["ram_samples"] = [[940, 100], [942, 2210]] + [[t, 991] for t in range(944, 1001, 2)]
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now), (2243, "adaptive"))
        self.job["ram_samples"] = self.job["ram_samples"][:-25] + [[995, 100], [997, 991]]
        self.assertEqual(rs.ram_allowance(self.job, self.config, 997)[0], 8192 - 991)

    def history(self, shares, **changes):
        return [
            {
                **dict(
                    state="completed",
                    exit_code=0,
                    failure=None,
                    category="render",
                    profile=dict(project="riso", name="auto-v1", variant=str(i)),
                    requested=dict(cpu=4, ram_mib=4096, vram_mib=0),
                    observed=dict(ram_peak_mib=4096 * share),
                    ram_good_samples=5,
                    ended_at=self.now - 60,
                ),
                **changes,
            }
            for i, share in enumerate(shares)
        ]

    def test_project_category_history_estimates_need_from_robust_peak_share(self):
        job = dict(
            state="queued",
            memory_policy="adaptive",
            category="render",
            profile=dict(project="riso", name="auto-v1", variant="new"),
            requested=dict(cpu=4, ram_mib=8192, vram_mib=0),
        )
        shares = [0.1] * 9 + [0.2] + [0.7]
        self.assertEqual(rs.ram_estimate(job, self.history(shares), self.config, self.now), 2663)
        self.assertEqual(rs.ram_estimate(job, self.history(shares[-5:]), self.config, self.now), 7168)
        self.assertIsNone(rs.ram_estimate(job, self.history(shares[-4:]), self.config, self.now))
        oom = self.history([0.1], state="failed", exit_code=137, failure="ram_oom")
        self.assertIsNone(rs.ram_estimate(job, self.history(shares) + oom, self.config, self.now))
        for other in (
            dict(category="build"),
            dict(profile=dict(project="other")),
            dict(ended_at=self.now - 31 * 86400),
        ):
            runs = [{**run, **other} for run in self.history(shares)]
            self.assertIsNone(rs.ram_estimate(job, runs, self.config, self.now))
        for changes in (dict(memory_policy="strict"), dict(profile=None)):
            self.assertIsNone(rs.ram_estimate({**job, **changes}, self.history(shares), self.config, self.now))
        self.assertIsNone(rs.ram_estimate(job, self.history(shares), {**self.config, "adaptive_ram": False}, self.now))

    def test_estimated_need_admits_where_hard_limit_would_not(self):
        self.candidate["requested"]["ram_mib"] = 12288
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIn("Insufficient RAM", rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            self.candidate["ram_estimate_mib"] = 3000
            self.assertIsNone(rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            strict = {**self.config, "adaptive_ram": False}
            self.assertIn("Insufficient RAM", rs.admission_reason(self.candidate, [], self.snapshot, strict))

    def test_startup_uses_estimate_until_the_job_leaves_its_envelope(self):
        self.job["ram_observed_since"] = 995
        self.job["ram_estimate_mib"] = 2000
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now), (1200, "learned-startup"))
        self.job["observed"]["ram_peak_mib"] = 2100
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now), (2272, "strict/startup/unknown"))
        self.job["observed"]["ram_peak_mib"] = 1400
        self.job["memory_policy"] = "strict"
        self.assertEqual(rs.ram_allowance(self.job, self.config, self.now)[1], "strict/startup/unknown")

    def test_missing_pressure_and_stale_host_snapshot_stop_admission(self):
        with patch.object(rs.time, "time", return_value=self.now):
            self.snapshot["pressure"]["memory"] = None
            self.assertIn("telemetry unavailable", rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            self.snapshot["pressure"]["memory"] = dict(full=dict(avg10=0))
            self.snapshot["sampled_at"] = 900
            self.assertIn("stale", rs.admission_reason(self.candidate, [], self.snapshot, self.config))

    def test_slurm_capacity_is_not_overstated_by_measured_admission(self):
        self.job["requested"]["ram_mib"] = 23000
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertEqual(
                rs.admission_reason(self.candidate, [self.job], self.snapshot, self.config),
                "Slurm RAM reservation capacity exhausted",
            )

    def test_pending_grant_keeps_budget_without_blanket_head_of_line_block(self):
        self.job["state"] = "pending"
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIsNone(rs.admission_reason(self.candidate, [self.job], self.snapshot, self.config))
            self.job["requested"]["ram_mib"] = 15000
            self.assertIn(
                "Insufficient RAM", rs.admission_reason(self.candidate, [self.job], self.snapshot, self.config)
            )

    def test_large_lane_is_not_a_slurm_memory_allocation(self):
        self.job.update(execution="large")
        self.job["requested"]["ram_mib"] = 23000
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIsNone(rs.admission_reason(self.candidate, [self.job], self.snapshot, self.config))

    def test_automatic_identity_is_private_exact_and_repo_scoped(self):
        request = dict(
            project="repo-a",
            category="build",
            requested=dict(cpu=3),
            payload=dict(cwd="/private/path", command=["bash", "-c", "tool --token secret-value"], env={}),
        )
        identity = rs.automatic_profile(request, "host-private-key")
        self.assertNotIn("secret-value", json.dumps(identity))
        self.assertNotIn("/private", json.dumps(identity))
        self.assertEqual(identity, rs.automatic_profile(copy.deepcopy(request), "host-private-key"))
        for changed in [dict(project="repo-b"), dict(requested=dict(cpu=4)), dict(origin="agent-sandbox-test")]:
            self.assertNotEqual(identity, rs.automatic_profile({**request, **changed}, "host-private-key"))
        request["payload"]["command"].append("other-input")
        self.assertNotEqual(identity, rs.automatic_profile(request, "host-private-key"))
        self.assertNotEqual(identity, rs.automatic_profile(request, "other-private-key"))

    def test_large_gpu_lane_bypasses_estimates_but_not_critical_exhaustion(self):
        self.config["large_gpu_lane"] = True
        self.candidate["requested"].update(vram_mib=26000, ram_mib=16384)
        self.snapshot["gpu"] = dict(free_mib=2000)
        self.snapshot["ram"]["available_mib"] = 3000
        self.snapshot["pressure"]["memory"]["some"] = dict(avg10=0)
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIsNone(rs.admission_reason(self.candidate, [self.job], self.snapshot, self.config))
            self.snapshot["ram"]["available_mib"] = 1000
            self.assertIn("Critical", rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            self.snapshot["ram"]["available_mib"] = 3000
            self.snapshot["gpu"]["free_mib"] = 500
            self.assertIn("Critical", rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            self.snapshot["gpu"]["free_mib"] = 2000
            self.snapshot["pressure"]["memory"]["full"]["avg10"] = 10
            self.assertIn("Severe", rs.admission_reason(self.candidate, [], self.snapshot, self.config))
            self.snapshot["pressure"]["memory"] = None
            self.assertIn("telemetry", rs.admission_reason(self.candidate, [], self.snapshot, self.config))

    def test_large_lane_has_one_occupant_and_strict_and_exploration_opt_out(self):
        self.config["large_gpu_lane"] = True
        self.candidate["requested"]["vram_mib"] = 26000
        active = {**copy.deepcopy(self.candidate), "state": "running"}
        with patch.object(rs.time, "time", return_value=self.now):
            self.assertIn("occupied", rs.admission_reason(self.candidate, [active], self.snapshot, self.config))
        self.candidate["memory_policy"] = "strict"
        self.assertFalse(rs.large_gpu_job(self.candidate, self.config))
        self.candidate.pop("memory_policy")
        self.candidate["explore"] = True
        self.assertFalse(rs.large_gpu_job(self.candidate, self.config))
        self.candidate["explore"] = False
        self.candidate["requested"]["vram_mib"] = 8192
        self.candidate["large_gpu"] = True
        self.assertTrue(rs.large_gpu_job(self.candidate, self.config))
        self.candidate["execution"] = "host"
        self.assertFalse(rs.large_gpu_job(self.candidate, self.config))

    def test_worktree_scope_uses_common_git_repository(self):
        result = type("Result", (), {"stdout": "/repo/.git\n/worktrees/child\n"})()
        with (
            patch.object(rs.os, "getcwd", return_value="/worktrees/child/frontend"),
            patch.object(rs.subprocess, "run", return_value=result),
        ):
            self.assertEqual(rs.workload_scope(), dict(profile_scope="/repo/.git", profile_relative_cwd="frontend"))


if __name__ == "__main__":
    unittest.main()
