import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import time

POLICY = os.environ.get("AGENT_EGRESS_POLICY", "/etc/agent-broker/egress.json")
RUNTIME = os.environ.get("AGENT_EGRESS_RUNTIME", "/var/lib/agent-broker-egress/allow.json")
UNIT = "agent-broker-egress-proxy.service"
PATTERN = re.compile(r"^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:([0-9]{1,5}|\*))?$")
DURATION = re.compile(r"^([0-9]+)([smhdw])$")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def die(message):
    print(f"agent-egress: {message}", file=sys.stderr)
    sys.exit(1)


def seconds(text):
    match = DURATION.match(text)
    if not match:
        die(f"invalid duration {text!r}; use for example 30m, 12h, 3w")
    return int(match.group(1)) * UNITS[match.group(2)]


def load_policy():
    try:
        with open(POLICY) as f:
            return json.load(f)
    except OSError:
        die(f"{POLICY} is missing: agentBroker.egress isn't enabled on this host")


def records(lines):
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("host") and record.get("decision") and record.get("event") != "close":
            yield record


def journal(since):
    command = ["journalctl", "--unit", UNIT, "--output", "cat", "--no-pager", "--since", since]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        die(f"journalctl failed: {result.stderr.strip()}")
    return result.stdout.splitlines()


def registrable(hosts):
    """Each host's registrable domain, from the public suffix list when psl is installed."""
    if shutil.which("psl"):
        result = subprocess.run(
            ["psl", "--print-reg-domain"], input="\n".join(hosts) + "\n", capture_output=True, text=True
        )
        mapping = {}
        for line in result.stdout.splitlines():
            host, _, domain = line.partition(": ")
            if domain and domain != "(null)":
                mapping[host] = domain
        if mapping:
            return mapping
    return {h: ".".join(h.split(".")[-2:]) for h in hosts}


def is_ip(host):
    return host == "localhost" or re.fullmatch(r"[0-9.]+|\[?[0-9a-fA-F:]+\]?", host) is not None


def summarize(stream):
    targets = collections.defaultdict(lambda: {"count": 0, "sandboxes": set(), "decisions": collections.Counter()})
    for record in stream:
        port = record.get("port") or 443
        key = (record["host"].lower().rstrip("."), int(port))
        entry = targets[key]
        entry["count"] += 1
        entry["decisions"][record["decision"]] += 1
        if record.get("sandbox"):
            entry["sandboxes"].add(record["sandbox"])
        entry["first"] = min(entry.get("first", record.get("ts", 0)), record.get("ts", 0))
        entry["last"] = max(entry.get("last", 0), record.get("ts", 0))
    return targets


def suggest(targets, allow, minimum):
    """Allowlist entries for what was seen and not yet allowed, collapsing busy domains to wildcards."""
    unseen = {k: v for k, v in targets.items() if v["decisions"].get("would-deny") or v["decisions"].get("deny")}
    hosts = sorted({h for h, _ in unseen if not is_ip(h)})
    domains = registrable(hosts)
    by_domain = collections.defaultdict(set)
    for host in hosts:
        by_domain[domains.get(host, host)].add(host)
    entries = set()
    for (host, port), _ in unseen.items():
        if is_ip(host):
            continue
        domain = domains.get(host, host)
        name = f"*.{domain}" if len(by_domain[domain]) >= minimum and host != domain else host
        entries.add(name if port in (80, 443) else f"{name}:{port}")
    return sorted(entries - set(allow))


def cmd_report(args):
    lines = sys.stdin.read().splitlines() if args.input == "-" else journal(args.since)
    targets = summarize(records(lines))
    policy = load_policy() if os.path.exists(POLICY) else {"allow": []}
    if args.nix:
        entries = suggest(targets, policy.get("allow", []), args.wildcard_after)
        print("agentBroker.egress.allow = [")
        for entry in entries:
            print(f'  "{entry}"')
        print("];")
        return
    rows = sorted(targets.items(), key=lambda kv: -kv[1]["count"])
    print(f"{'host:port':50} {'requests':>8} {'sandboxes':>9}  decisions")
    for (host, port), v in rows:
        decisions = ", ".join(f"{d} {n}" for d, n in v["decisions"].most_common())
        print(f"{host + ':' + str(port):50} {v['count']:>8} {len(v['sandboxes']):>9}  {decisions}")


def write_runtime(entries):
    directory = os.path.dirname(RUNTIME)
    os.makedirs(directory, exist_ok=True)
    tmp = RUNTIME + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"allow": entries}, f, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, RUNTIME)


def read_runtime():
    try:
        with open(RUNTIME) as f:
            entries = json.load(f).get("allow", [])
    except (OSError, ValueError):
        return []
    now = time.time()
    return [e for e in entries if e.get("expires") is None or e["expires"] > now]


def elevate():
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", "--", sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]])


def cmd_allow(args):
    if not PATTERN.match(args.pattern):
        die(f"invalid host pattern {args.pattern!r}; use host, *.domain, host:port or host:*")
    elevate()
    entries = [e for e in read_runtime() if e["pattern"] != args.pattern]
    expires = None if args.forever else time.time() + seconds(args.duration)
    entries.append({"pattern": args.pattern, "expires": expires, "added": int(time.time())})
    write_runtime(entries)
    until = "until removed" if expires is None else time.strftime("until %Y-%m-%d %H:%M", time.localtime(expires))
    print(f"agent-egress: allowed {args.pattern} {until}; add it to agentBroker.egress.allow to keep it")


def cmd_revoke(args):
    elevate()
    entries = read_runtime()
    kept = [e for e in entries if e["pattern"] != args.pattern]
    if len(kept) == len(entries):
        die(f"{args.pattern} isn't a runtime entry")
    write_runtime(kept)
    print(f"agent-egress: removed {args.pattern}")


def cmd_status(args):
    policy = load_policy()
    print(f"mode: {policy.get('mode')}")
    print(f"allowlist: {len(policy.get('allow', []))} entries from Nix")
    for entry in read_runtime():
        until = (
            "forever"
            if entry.get("expires") is None
            else time.strftime("%Y-%m-%d %H:%M", time.localtime(entry["expires"]))
        )
        print(f"runtime: {entry['pattern']} until {until}")
    for binding in policy.get("inject", []):
        present = "present" if os.path.exists(binding["file"]) else "missing (bound hosts answer 503)"
        print(f"credential {binding['name']}: {', '.join(binding['hosts'])}, value {present}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="agent-egress", description="Inspect and adjust the sandboxes' egress allowlist"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    report = sub.add_parser("report", help="summarize the proxy log")
    report.add_argument("--since", default="3 weeks ago")
    report.add_argument("--nix", action="store_true", help="print a Nix allowlist of what isn't allowed yet")
    report.add_argument(
        "--wildcard-after", type=int, default=3, help="subdomains of one domain before suggesting *.domain"
    )
    report.add_argument("--input", default=None, help="read log lines from - (stdin) instead of the journal")
    report.set_defaults(func=cmd_report)
    allow = sub.add_parser("allow", help="allow a host at runtime, without a switch")
    allow.add_argument("pattern")
    allow.add_argument("--for", dest="duration", default="1h")
    allow.add_argument("--forever", action="store_true")
    allow.set_defaults(func=cmd_allow)
    revoke = sub.add_parser("revoke", help="remove a runtime allow entry")
    revoke.add_argument("pattern")
    revoke.set_defaults(func=cmd_revoke)
    status = sub.add_parser("status", help="show the mode, runtime entries and credential bindings")
    status.set_defaults(func=cmd_status)
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
