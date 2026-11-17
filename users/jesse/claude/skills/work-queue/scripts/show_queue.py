#!/usr/bin/env python3
"""Render one read-only shared scheduler snapshot as a work-oriented text tree."""

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone

TERMINAL = {"completed", "failed", "cancelled"}
GROUPS = (
    ("RUNNING", {"running"}),
    ("STARTING / ALLOCATION PENDING", {"pending", "starting"}),
    ("WAITING", {"queued"}),
    ("UNCERTAIN / OTHER", set()),
)


def clean(value):
    return " ".join("".join(c if c.isprintable() else " " for c in str(value)).split())


def tree(nodes, prefix=""):
    for index, (label, children) in enumerate(nodes):
        last = index == len(nodes) - 1
        yield prefix + ("`-- " if last else "|-- ") + label
        yield from tree(children, prefix + ("    " if last else "|   "))


def render(snapshot, project=None):
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("jobs"), list):
        raise ValueError("scheduler response has no jobs list")
    timestamp = snapshot.get("generated_at")
    stamp = (
        datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        if timestamp
        else "time unknown"
    )
    lines = [f"WORK QUEUE | {stamp}", f"Scheduler: {clean(snapshot.get('mode', 'unknown'))}"]
    if project:
        lines.append(f"Project filter: {clean(project)}")
    if snapshot.get("connected") is False:
        lines.append("! Scheduler disconnected; snapshot may be stale")
    lines.extend(f"! {clean(error)}" for error in snapshot.get("errors", []))
    jobs = [
        job
        for job in snapshot["jobs"]
        if job.get("state") not in TERMINAL and (project is None or job.get("project") == project)
    ]
    nodes = []
    known = set().union(*(states for _, states in GROUPS))
    for title, states in GROUPS:
        selected = [j for j in jobs if j.get("state") in states or (not states and j.get("state") not in known)]
        if not selected:
            continue
        projects = defaultdict(list)
        for job in selected:
            details = []
            card = job.get("worktree_name")
            parent = job.get("parent_worktree_name")
            if card:
                details.append((f"Card: {clean(parent) + ' / ' if parent else ''}{clean(card)}", []))
            reason = job.get("wait_reason")
            if reason:
                details.append((clean(reason), []))
            cleanup = job.get("cleanup")
            if cleanup and cleanup not in {"pending", "complete"}:
                details.append((f"Cleanup: {clean(cleanup)}", []))
            position = job.get("queue_position")
            place = f" [queue #{clean(position)}]" if position is not None else ""
            label = clean(job.get("label") or "Unnamed job")
            state = clean(job.get("state") or "unknown")
            job_id = clean(job.get("id") or "ID unavailable")
            projects[clean(job.get("project") or "project unknown")].append(
                (f"{label} [{state}]{place}", [(f"ID: {job_id}", []), *details])
            )
        nodes.append((f"{title} ({len(selected)})", list(projects.items())))
    lines.extend(tree(nodes))
    if not jobs:
        lines.append("`-- No active jobs reported" if snapshot.get("errors") else "`-- No active jobs")
    if any(j.get("queue_position") is not None for j in jobs):
        lines.append("Queue positions are a snapshot; admission may let smaller jobs pass.")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", help="Exact scheduler project key; default shows every project")
    args = parser.parse_args()
    try:
        result = subprocess.run(["resource-status", "--json"], capture_output=True, text=True, timeout=20, check=True)
        print(render(json.loads(result.stdout), args.project))
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, OverflowError) as error:
        print(f"Work queue unavailable: {clean(error)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
