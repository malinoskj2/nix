import argparse
import html
import json
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time


GIB = 1024**3
POLL_SECONDS = 30
ALERT_GIB = 28
REARM_GIB = 26
ALERT_EXPIRE_MS = 10_000
NEVER_EXPIRE = 0
CONTEXT_SECONDS = 30
MAX_CONTEXTS = 128
MAX_QUEUED_EVENTS = 128


def scope_of(cgroup):
    return "sandbox" if "agent-sandbox.slice" in cgroup.split("/") else "host"


def read_memory(path=Path("/proc/meminfo")):
    fields = {}
    for line in path.read_text().splitlines():
        name, value = line.split(":", 1)
        fields[name] = int(value.split()[0]) * 1024
    return fields


class MemoryAlert:
    def __init__(self):
        self.active = False

    def check(self, fields, notify):
        used = fields["MemTotal"] - fields["MemAvailable"]
        if used <= REARM_GIB * GIB:
            self.active = False
        if used > ALERT_GIB * GIB and not self.active:
            swap = fields["SwapTotal"] - fields["SwapFree"]
            body = (
                f"RAM: {used / GIB:.1f} / "
                f"{fields['MemTotal'] / GIB:.1f} GiB used.\n"
                f"Swap: {swap / GIB:.1f} GiB used.\n"
                f"Another RAM alert is enabled after usage falls to {REARM_GIB} GiB."
            )
            self.active = notify(f"Memory usage above {ALERT_GIB} GiB", body, ALERT_EXPIRE_MS)


def oomd_alert(message):
    killed = re.match(r"Killed (/\S+) due to ", message)
    if killed:
        return f"OOM killed a {scope_of(killed[1])} cgroup", message
    return None


class OomAlerts:
    def __init__(self):
        # Kernel context by victim PID, so overlapping OOMs do not borrow each
        # other's cgroup. Kept bounded even if a kill line is lost.
        self.contexts = {}

    def feed(self, entry, now):
        message = entry.get("MESSAGE", "")
        if not isinstance(message, str):
            return None
        if entry.get("_SYSTEMD_UNIT") == "systemd-oomd.service":
            return oomd_alert(message)
        if entry.get("_TRANSPORT") != "kernel":
            return None

        self.expire(now)
        if message.startswith("oom-kill:"):
            self.remember(message, now)
            return None
        return self.victim_alert(message)

    def expire(self, now):
        self.contexts = {
            pid: (seen, fields) for pid, (seen, fields) in self.contexts.items() if now - seen < CONTEXT_SECONDS
        }

    def remember(self, message, now):
        fields = dict(re.findall(r"(?:^|,)(\w+)=([^,]+)", message.removeprefix("oom-kill:")))
        pid = fields.get("pid")
        if pid:
            if len(self.contexts) >= MAX_CONTEXTS:
                self.contexts.pop(next(iter(self.contexts)))
            self.contexts[pid] = now, fields

    def victim_alert(self, message):
        victim = re.match(
            r"(Out of memory|Memory cgroup out of memory): "
            r"Killed process (\d+) \((.*)\) total-vm:",
            message,
        )
        if not victim:
            return None

        reason, pid, name = victim.groups()
        _, fields = self.contexts.pop(pid, (None, {}))
        cgroup = fields.get("task_memcg") or fields.get("oom_memcg")
        cgroup_limit = reason.startswith("Memory cgroup")
        if cgroup:
            scope = scope_of(cgroup)
        else:
            scope = "cgroup" if cgroup_limit else "host"
        cause = "Cgroup memory limit" if cgroup_limit else "Host out of memory"
        body = f"{name} (PID {pid}) was killed.\nCause: {cause}."
        if cgroup:
            body += f"\nCgroup: {cgroup}"
        return f"OOM killed {name} ({scope})", body


def send_notification(command, title, body, expire_ms):
    print(f"{title}: {body}", flush=True)
    try:
        subprocess.run(
            [
                command,
                "--app-name=Memory monitor",
                "--urgency=critical",
                "--icon=dialog-warning",
                f"--expire-time={expire_ms}",
                "--",
                title,
                html.escape(body),
            ],
            check=True,
            timeout=5,
        )
        return True
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Notification failed: {error}", file=sys.stderr, flush=True)
        return False


def read_journal(process, events):
    for line in process.stdout:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            events.put(entry)
    events.put(None)


def follow_journal(journalctl):
    events = queue.Queue(maxsize=MAX_QUEUED_EVENTS)
    journal = subprocess.Popen(
        [
            journalctl,
            "--boot",
            "--follow",
            "--lines=0",
            "--output=json",
            "--grep=oom-kill:|[Oo]ut of memory: Killed process|Killed .* due to",
            "_TRANSPORT=kernel",
            "+",
            "_SYSTEMD_UNIT=systemd-oomd.service",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    threading.Thread(target=read_journal, args=(journal, events), daemon=True).start()
    return journal, events


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main():
    parser = argparse.ArgumentParser(description="RAM and OOM desktop alerts")
    parser.add_argument("--journalctl", required=True)
    parser.add_argument("--notify-send", required=True)
    args = parser.parse_args()

    def notify(title, body, expire_ms):
        return send_notification(args.notify_send, title, body, expire_ms)

    journal, events = follow_journal(args.journalctl)
    memory = MemoryAlert()
    oom = OomAlerts()
    next_check = 0
    try:
        while True:
            if time.monotonic() >= next_check:
                memory.check(read_memory(), notify)
                next_check = time.monotonic() + POLL_SECONDS
            try:
                entry = events.get(timeout=max(0, next_check - time.monotonic()))
            except queue.Empty:
                continue
            if entry is None:
                raise RuntimeError("Host journal follower stopped")
            alert = oom.feed(entry, time.monotonic())
            if alert:
                title, body = alert
                notify(title, body, NEVER_EXPIRE)
    finally:
        stop(journal)


if __name__ == "__main__":
    main()
