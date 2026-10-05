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


def in_sandbox(cgroup):
    return "agent-sandbox.slice" in cgroup.split("/")


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
        if used <= 26 * GIB:
            self.active = False
        if used > 28 * GIB and not self.active:
            swap = fields["SwapTotal"] - fields["SwapFree"]
            body = (
                f"RAM: {used / GIB:.1f} / "
                f"{fields['MemTotal'] / GIB:.1f} GiB used.\n"
                f"Swap: {swap / GIB:.1f} GiB used.\n"
                "Another RAM alert is enabled after usage falls to 26 GiB."
            )
            self.active = notify("Memory usage above 28 GiB", body, 10000)


class OomAlerts:
    def __init__(self):
        self.contexts = {}

    def feed(self, entry, now):
        message = entry.get("MESSAGE", "")
        if not isinstance(message, str):
            return None

        if entry.get("_SYSTEMD_UNIT") == "systemd-oomd.service":
            killed = re.match(r"Killed (/\S+) due to ", message)
            if killed:
                scope = "sandbox" if in_sandbox(killed[1]) else "host"
                return f"OOM killed a {scope} cgroup", message
            return None

        if entry.get("_TRANSPORT") != "kernel":
            return None

        # Match context to the victim PID, so overlapping OOMs do not borrow
        # each other's cgroup. Keep this bounded even if a kill line is lost.
        self.contexts = {pid: context for pid, context in self.contexts.items() if now - context[0] < 30}
        if message.startswith("oom-kill:"):
            fields = dict(re.findall(r"(?:^|,)(\w+)=([^,]+)", message[9:]))
            pid = fields.get("pid")
            if pid:
                if len(self.contexts) >= 128:
                    self.contexts.pop(next(iter(self.contexts)))
                self.contexts[pid] = now, fields
            return None

        victim = re.match(
            r"(Out of memory|Memory cgroup out of memory): "
            r"Killed process (\d+) \((.*)\) total-vm:",
            message,
        )
        if not victim:
            return None

        reason, pid, name = victim.groups()
        _, fields = self.contexts.pop(pid, (now, {}))
        cgroup = fields.get("task_memcg") or fields.get("oom_memcg")
        if cgroup:
            scope = "sandbox" if in_sandbox(cgroup) else "host"
        else:
            scope = "cgroup" if reason.startswith("Memory cgroup") else "host"
        cause = "Cgroup memory limit" if reason.startswith("Memory cgroup") else "Host out of memory"
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


def main():
    parser = argparse.ArgumentParser(description="RAM and OOM desktop alerts")
    parser.add_argument("--journalctl", required=True)
    parser.add_argument("--notify-send", required=True)
    args = parser.parse_args()

    def notify(title, body, expire_ms):
        return send_notification(args.notify_send, title, body, expire_ms)

    events = queue.Queue(maxsize=128)
    journal = subprocess.Popen(
        [
            args.journalctl,
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
    memory = MemoryAlert()
    oom = OomAlerts()
    next_check = 0
    try:
        while True:
            now = time.monotonic()
            if now >= next_check:
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
                notify(*alert, 0)
    finally:
        journal.terminate()
        try:
            journal.wait(timeout=5)
        except subprocess.TimeoutExpired:
            journal.kill()
            journal.wait()


if __name__ == "__main__":
    main()
