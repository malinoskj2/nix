"""Unprivileged Orca completion delivery. Scheduler state owns claims and receipts."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

# Load only the sibling immutable store module under Python isolated mode.
spec = importlib.util.spec_from_file_location("resource_scheduler", Path(__file__).with_name("resource_scheduler.py"))
scheduler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheduler)
rpc = scheduler.rpc


def orca_call(executable, args):
    # This service's environment is trusted, never a submitted job environment.
    environment = {k: v for k, v in os.environ.items() if not k.startswith("ORCA_")}
    result = subprocess.run(
        [executable, *args, "--environment", "local", "--json"],
        capture_output=True,
        text=True,
        timeout=20,
        env=environment,
    )
    value = json.loads(result.stdout)
    if result.returncode or value.get("ok") is not True:
        raise RuntimeError("Orca request unavailable")
    return value["result"]


def session_present(workspaces, session):
    if not session or not re.fullmatch(r"[A-Za-z0-9_-]{1,160}", session):
        return False
    # Match the exact structured-session identity, never titles, cwd or another
    # agent on the same card. Terminal-only or ambiguous identities stay in inbox.
    prefix = "structured-agent-session-" + session + ":"
    matches = [
        agent
        for workspace in workspaces
        for agent in workspace.get("agents", [])
        if workspace.get("hostId") == "local"
        and not workspace.get("isArchived")
        and agent.get("paneKey", "").startswith(prefix)
    ]
    return len(matches) == 1 and matches[0].get("structuredHostOwned") is True


def message(item):
    job_id = item["id"]
    # Do not include job labels, command text or output in agent-driving messages.
    state = (
        item["state"]
        if item["state"] in ("completed", "failed", "cancelled", "running", "queued", "unknown")
        else "unknown"
    )
    failure = item.get("failure")
    if failure not in (
        None,
        "ram_oom",
        "gpu_oom_reported",
        "command_failed",
        "time_limit",
        "cancelled",
        "exploration_headroom",
    ):
        failure = "unknown"
    code = item.get("exit_code")
    if type(code) is not int:
        code = "unknown"
    return (
        f"Resource job {job_id} {state}; exit={code}; outcome={failure or state}.\n"
        f"Inspect: resource-job inspect {job_id} --json\n"
        f"Output: resource-job logs {job_id}\n"
        "This is a state-change snapshot; inspect the current job before acting. "
        "If you are a supervised worker, report the current status to your existing coordinator "
        "using your dispatch mailbox, including whether the previous blocker is cleared. "
        f"After handling this update, acknowledge it: resource-job ack {job_id} --confirm\n"
        "Inspect this result and continue the existing authorized task if appropriate. "
        "This notification does not authorize automatic retries, new work, or a cancelled task's resumption."
        + (
            "\nRAM OOM: the job reached its declared RAM limit and was killed. Resubmitting the same work "
            "with a larger --ram is part of the existing task, not a blind retry."
            if failure == "ram_oom"
            else ""
        )
    )


def deliver_once(executable, call=orca_call, request=rpc):
    items = request(dict(action="notifications"))["notifications"]
    pending = [item for item in items if item["notification"]["state"] == "pending" and item["ready"]]
    if not pending:
        return
    # If Orca is down, leave work pending: no send was attempted.
    result = call(executable, ["worktree", "ps", "--limit", "10000"])
    if result.get("truncated"):
        return
    workspaces = result["worktrees"]
    for item in pending[:20]:
        job_id = item["id"]
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            continue
        session = item["notification"].get("session")
        try:
            claim = request(
                dict(action="notification-claim", id=job_id, generation=item["notification"].get("generation"))
            )
        except (OSError, RuntimeError):
            continue  # A waiter or another notifier won the claim.
        state, detail = "unavailable", "Submitting session unavailable; review the completion inbox"
        if session_present(workspaces, session):
            try:
                receipt = call(
                    executable,
                    [
                        "orchestration",
                        "send",
                        "--to",
                        "orca_session_id:" + session,
                        "--from",
                        "resource-scheduler",
                        "--type",
                        "status",
                        "--subject",
                        "Resource job state changed",
                        "--body",
                        message(item),
                    ],
                )
                # A durable Orca message receipt proves acceptance, not that the
                # agent has read it. Do not treat a successful process exit alone as delivery.
                if isinstance(receipt.get("messageId"), str) and receipt["messageId"]:
                    state, detail = "delivered", "Accepted by Orca for the exact submitting session"
                else:
                    detail = "Orca delivery receipt uncertain; inspect inbox before any manual resend"
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                detail = "Orca delivery outcome uncertain; inspect inbox before any manual resend"
        try:
            request(dict(action="notification-finish", id=job_id, token=claim["token"], state=state, detail=detail))
        except (OSError, RuntimeError):
            # A newer job state can supersede this in-flight delivery. Never mark it delivered.
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orca", required=True)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if not Path(args.orca).is_absolute():
        parser.error("Use the absolute path to the host Orca CLI")
    while True:
        try:
            deliver_once(args.orca)
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError):
            print(
                "resource-notify: delivery unavailable; pending outcomes remain in resource-job notifications",
                flush=True,
            )
        if args.once:
            return
        time.sleep(10)


if __name__ == "__main__":
    main()
