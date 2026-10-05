import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("monitor", Path(__file__).with_name("memory-notifications.py"))
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


def memory(used):
    return {
        "MemTotal": 32 * monitor.GIB,
        "MemAvailable": (32 - used) * monitor.GIB,
        "SwapTotal": 16 * monitor.GIB,
        "SwapFree": 15 * monitor.GIB,
    }


def kernel(message):
    return {"_TRANSPORT": "kernel", "MESSAGE": message}


def context(pid, cgroup):
    return kernel(
        f"oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),"
        f"cpuset=/,mems_allowed=0,oom_memcg={cgroup},"
        f"task_memcg={cgroup},task=python3,pid={pid},uid=1000"
    )


def victim(pid, reason="Memory cgroup out of memory"):
    return kernel(
        f"{reason}: Killed process {pid} (python3) "
        "total-vm:123456kB, anon-rss:100000kB, file-rss:0kB, "
        "shmem-rss:0kB, UID:1000 pgtables:100kB oom_score_adj:0"
    )


class MemoryTests(unittest.TestCase):
    def test_threshold_hysteresis_and_rearm(self):
        alert = monitor.MemoryAlert()
        notify = Mock(return_value=True)
        for used in [28, 28.1, 29, 27, 28.5]:
            alert.check(memory(used), notify)
        self.assertEqual(notify.call_count, 1)
        alert.check(memory(26), notify)
        alert.check(memory(29), notify)
        self.assertEqual(notify.call_count, 2)

    def test_failed_delivery_is_retried(self):
        alert = monitor.MemoryAlert()
        notify = Mock(side_effect=[False, True])
        alert.check(memory(29), notify)
        alert.check(memory(29), notify)
        self.assertEqual(notify.call_count, 2)

    def test_available_memory_instead_of_free_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "meminfo"
            path.write_text(
                "MemTotal: 33554432 kB\nMemAvailable: 8388608 kB\n"
                "MemFree: 1048576 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"
            )
            fields = monitor.read_memory(path)
        notify = Mock(return_value=True)
        monitor.MemoryAlert().check(fields, notify)
        notify.assert_not_called()


class OomTests(unittest.TestCase):
    def test_overlapping_host_and_sandbox_kills_match_the_victim(self):
        alerts = monitor.OomAlerts()
        sandbox = "/agent-sandbox.slice/docker-abc.scope"
        host = "/system.slice/nix-daemon.service"
        self.assertIsNone(alerts.feed(context(42, sandbox), 1))
        self.assertIsNone(alerts.feed(context(43, host), 2))
        title, body = alerts.feed(victim(42), 3)
        self.assertIn("sandbox", title)
        self.assertIn(sandbox, body)
        self.assertIn("Cgroup memory limit", body)
        title, body = alerts.feed(victim(43), 4)
        self.assertIn("host", title)
        self.assertIn(host, body)

    def test_global_oom_can_kill_a_sandbox_process(self):
        alerts = monitor.OomAlerts()
        alerts.feed(context(42, "/agent-sandbox.slice/docker-abc.scope"), 1)
        title, body = alerts.feed(victim(42, "Out of memory"), 2)
        self.assertIn("sandbox", title)
        self.assertIn("Host out of memory", body)

    def test_missing_or_expired_context_still_reports_kill(self):
        alerts = monitor.OomAlerts()
        alerts.feed(context(42, "/agent-sandbox.slice/docker-old.scope"), 1)
        title, body = alerts.feed(victim(42, "Out of memory"), 32)
        self.assertIn("host", title)
        self.assertNotIn("docker-old", body)
        title, body = alerts.feed(victim(43), 33)
        self.assertIn("cgroup", title)
        self.assertIn("PID 43", body)

    def test_oomd_memory_pressure_and_swap_kills(self):
        alerts = monitor.OomAlerts()
        for cgroup, scope in [
            ("/agent-sandbox.slice", "sandbox"),
            ("/user.slice/user-1000.slice/app.scope", "host"),
        ]:
            for reason in ["memory pressure", "memory used and swap used"]:
                message = f"Killed {cgroup} due to {reason} being too high"
                title, body = alerts.feed(
                    {
                        "_SYSTEMD_UNIT": "systemd-oomd.service",
                        "MESSAGE": message,
                    },
                    1,
                )
                self.assertIn(scope, title)
                self.assertEqual(body, message)

    def test_non_kills_and_untrusted_messages_do_not_alert(self):
        alerts = monitor.OomAlerts()
        for entry in [
            kernel("python3 invoked oom-killer: gfp_mask=0x0"),
            kernel("oom_reaper: reaped process 42 (python3)"),
            {"MESSAGE": victim(42)["MESSAGE"]},
            {"_TRANSPORT": "kernel", "MESSAGE": [98, 97, 100]},
            {
                "_SYSTEMD_UNIT": "systemd-oomd.service",
                "MESSAGE": "Failed to kill any cgroups based on swap",
            },
        ]:
            self.assertIsNone(alerts.feed(entry, 1))

    def test_context_storage_is_bounded(self):
        alerts = monitor.OomAlerts()
        for pid in range(200):
            alerts.feed(context(pid, "/agent-sandbox.slice"), 1)
        self.assertEqual(len(alerts.contexts), 128)


class DeliveryTests(unittest.TestCase):
    def test_critical_notification_escapes_markup_and_does_not_use_shell(self):
        with patch.object(monitor.subprocess, "run") as run:
            self.assertTrue(monitor.send_notification("notify-send", "OOM", "<python>&", 0))
        args = run.call_args.args[0]
        self.assertIn("--urgency=critical", args)
        self.assertIn("--expire-time=0", args)
        self.assertEqual(args[-1], "&lt;python&gt;&amp;")
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_notification_timeout_is_logged_without_stopping_monitor(self):
        with patch.object(
            monitor.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired("notify-send", 5),
        ):
            self.assertFalse(monitor.send_notification("notify-send", "OOM", "python", 0))


if __name__ == "__main__":
    unittest.main()
