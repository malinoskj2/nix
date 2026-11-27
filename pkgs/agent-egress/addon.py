import asyncio
import fnmatch
import ipaddress
import json
import os
import socket
import struct
import sys
import time

from mitmproxy import http
from mitmproxy.proxy import layers

WEB_PORTS = (80, 443)
MISSING = (
    b'{"error":"credential_unavailable","message":"agent-broker has no value for this host\'s '
    b'credential; the owner must add it with secret add"}\n'
)


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def stamp(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (os.path.realpath(path), st.st_ino, st.st_mtime_ns, st.st_size)


def split_target(entry):
    host, sep, port = entry.rpartition(":")
    if sep and (port == "*" or port.isdigit()) and "]" not in port:
        return host.lower(), port
    return entry.lower(), None


def host_matches(host, pattern):
    host = host.lower().rstrip(".")
    if pattern.startswith("*."):
        return host == pattern[2:] or fnmatch.fnmatchcase(host, pattern)
    return host == pattern


def entry_matches(entry, host, port, default=WEB_PORTS):
    pattern, want = split_target(entry)
    if not host_matches(host, pattern):
        return False
    if want is None:
        return port in default
    return want == "*" or int(want) == port


def internal_address(ip):
    """Addresses that reach the host itself or cloud metadata, which no sandbox may reach through the proxy."""
    try:
        address = ipaddress.ip_address(ip.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return address.is_loopback or address.is_link_local or address.is_unspecified or address.is_multicast


def socket_owner(peer, local):
    """The uid owning the IPv4 TCP socket bound at peer and connected to local, if any."""

    def hexaddr(addr):
        ip, port = addr[0], addr[1]
        return "%08X:%04X" % (struct.unpack("<I", socket.inet_aton(ip))[0], port)

    want_local, want_remote = hexaddr(peer), hexaddr(local)
    try:
        with open("/proc/self/net/tcp") as f:
            next(f)
            for line in f:
                fields = line.split()
                if fields[1] == want_local and fields[2] == want_remote:
                    return int(fields[7])
    except (OSError, StopIteration, ValueError):
        pass
    return None


class Policy:
    def __init__(self, path, peers_path, runtime_path):
        self.path, self.peers_path, self.runtime_path = path, peers_path, runtime_path
        self.stamps = None
        self.config = {"mode": "log", "allow": [], "inspect": [], "inject": []}
        self.peers = {}
        self.runtime = []
        self.secret_cache = {}

    def refresh(self, emit):
        stamps = (stamp(self.path), stamp(self.peers_path), stamp(self.runtime_path))
        if stamps == self.stamps:
            return
        changed_policy = self.stamps is None or stamps[0] != self.stamps[0]
        self.stamps = stamps
        self.config = read_json(self.path, self.config)
        self.peers = read_json(self.peers_path, {})
        self.runtime = read_json(self.runtime_path, {}).get("allow", [])
        if changed_policy:
            emit({"event": "reload", "mode": self.config.get("mode"), "allow": len(self.config.get("allow", []))})

    @property
    def mode(self):
        return "enforce" if self.config.get("mode") == "enforce" else "log"

    def binding(self, host, port):
        for b in self.config.get("inject", []):
            if any(entry_matches(p, host, port, (80, 443)) for p in b["hosts"]):
                return b
        return None

    def inspected(self, host, port):
        return self.binding(host, port) is not None or any(
            entry_matches(p, host, port) for p in self.config.get("inspect", [])
        )

    def allowed(self, sandbox, host, port):
        if self.binding(host, port) is not None:
            return True
        if any(entry_matches(e, host, port) for e in self.config.get("allow", [])):
            return True
        now = time.time()
        for e in self.runtime:
            if (e.get("expires") is None or e["expires"] > now) and entry_matches(e["pattern"], host, port):
                return True
        preview = (self.peers.get(sandbox) or {}).get("preview") or {}
        return host == preview.get("address") and port in preview.get("ports", [])

    def secret(self, binding):
        path = binding["file"]
        key = stamp(path)
        if key is None:
            return None
        cached = self.secret_cache.get(path)
        if cached and cached[0] == key:
            return cached[1]
        try:
            with open(path) as f:
                value = f.read().strip()
        except OSError:
            return None
        if not value:
            return None
        self.secret_cache[path] = (key, value)
        return value


class Broker:
    def __init__(self):
        self.policy = Policy(
            os.environ.get("AGENT_EGRESS_POLICY", "/etc/agent-broker/egress.json"),
            os.environ.get("AGENT_EGRESS_PEERS", "/run/agent-broker/egress-gate/peers.json"),
            os.environ.get("AGENT_EGRESS_RUNTIME", "/var/lib/agent-broker-egress/allow.json"),
        )
        self.uid = os.getuid()
        self.check_owner = os.environ.get("AGENT_EGRESS_CHECK_OWNER", "1") == "1"
        self.allow_internal = os.environ.get("AGENT_EGRESS_ALLOW_INTERNAL") == "1"
        self.policy.refresh(self.emit)

    def emit(self, record):
        record = {"ts": round(time.time(), 3), **record}
        sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def identify(self, client):
        cached = getattr(client, "agent_sandbox", False)
        if cached is not False:
            return cached
        sandbox = None
        address = client.peername[0] if client.peername else None
        for name, peer in self.policy.peers.items():
            if peer.get("address") == address:
                sandbox = name
        if sandbox and self.check_owner:
            owner = socket_owner(client.peername, client.sockname)
            if owner != self.uid:
                sandbox = None
        client.agent_sandbox = sandbox
        return sandbox

    def decide(self, sandbox, host, port):
        if sandbox is None:
            return "deny-identity", False
        if self.policy.allowed(sandbox, host, port):
            return "allow", True
        if self.policy.mode == "log":
            return "would-deny", True
        return "deny", False

    def http_connect(self, flow: http.HTTPFlow):
        self.policy.refresh(self.emit)
        client = flow.client_conn
        sandbox = self.identify(client)
        host, port = flow.request.host, flow.request.port
        decision, ok = self.decide(sandbox, host, port)
        client.agent_target = (host, port)
        client.agent_decision = decision
        self.emit({"sandbox": sandbox, "host": host, "port": port, "method": "CONNECT", "decision": decision})
        if not ok:
            flow.response = http.Response.make(403, b"agent-broker: egress to this host is not allowed\n")

    async def server_connect(self, data):
        if self.allow_internal:
            return
        host, port = data.server.address
        try:
            infos = await asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM)
        except OSError:
            return
        if any(internal_address(info[4][0]) for info in infos):
            data.server.error = "agent-broker: the host's own and link-local addresses are not reachable"
            self.emit(
                {
                    "sandbox": getattr(data.client, "agent_sandbox", None),
                    "host": host,
                    "port": port,
                    "decision": "deny-internal",
                }
            )

    def next_layer(self, nextlayer):
        context = nextlayer.context
        target = getattr(context.client, "agent_target", None)
        address = context.server.address
        if not target or not address or address[1] in WEB_PORTS:
            return
        if not self.policy.inspected(target[0], address[1]):
            nextlayer.layer = layers.TCPLayer(context, ignore=True)

    def tls_clienthello(self, data):
        target = getattr(data.context.client, "agent_target", None)
        host = data.client_hello.sni or (target[0] if target else "")
        port = target[1] if target else 443
        if not self.policy.inspected(host, port):
            data.ignore_connection = True

    def requestheaders(self, flow: http.HTTPFlow):
        if flow.request.method == "CONNECT":
            return
        self.policy.refresh(self.emit)
        flow.request.headers.pop("Proxy-Authorization", None)
        sandbox = self.identify(flow.client_conn)
        host, port = flow.request.pretty_host, flow.request.port
        decision, ok = self.decide(sandbox, host, port)
        flow.metadata["agent"] = {"sandbox": sandbox, "decision": decision, "injected": None}
        if not ok:
            flow.response = http.Response.make(403, b"agent-broker: egress to this host is not allowed\n")
            return
        binding = self.policy.binding(host, port)
        if binding is None:
            return
        if flow.request.scheme != "https":
            flow.metadata["agent"]["decision"] = "deny-cleartext"
            flow.response = http.Response.make(403, b"agent-broker: credentials are only sent over https\n")
            return
        value = self.policy.secret(binding)
        header = binding.get("header", "Authorization")
        flow.request.headers.pop(header, None)
        if value is None:
            flow.metadata["agent"]["decision"] = "deny-missing-secret"
            flow.response = http.Response.make(503, MISSING, {"Content-Type": "application/json"})
            return
        flow.request.headers[header] = binding.get("format", "Bearer {}").replace("{}", value)
        flow.metadata["agent"]["injected"] = binding["name"]

    def responseheaders(self, flow: http.HTTPFlow):
        flow.response.stream = True

    def response(self, flow: http.HTTPFlow):
        self.record(flow)

    def error(self, flow: http.HTTPFlow):
        self.record(flow)

    def record(self, flow):
        if flow.request.method == "CONNECT":
            return
        agent = flow.metadata.get("agent") or {}
        response = flow.response
        length = response.headers.get("content-length", "") if response else ""
        self.emit(
            {
                "sandbox": agent.get("sandbox"),
                "host": flow.request.pretty_host,
                "port": flow.request.port,
                "method": flow.request.method,
                "path": flow.request.path.split("?", 1)[0][:512],
                "decision": agent.get("decision"),
                "injected": agent.get("injected"),
                "status": response.status_code if response else None,
                "bytes_out": int(flow.request.headers.get("content-length", "0") or 0)
                if flow.request.headers.get("content-length", "0").isdigit()
                else None,
                "bytes_in": int(length) if length.isdigit() else None,
                "error": flow.error.msg[:200] if flow.error else None,
            }
        )

    def client_disconnected(self, client):
        target = getattr(client, "agent_target", None)
        if target:
            self.emit(
                {
                    "sandbox": getattr(client, "agent_sandbox", None),
                    "host": target[0],
                    "port": target[1],
                    "event": "close",
                    "decision": getattr(client, "agent_decision", None),
                    "seconds": round(time.time() - client.timestamp_start, 3),
                }
            )


addons = [Broker()]
