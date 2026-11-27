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
from OpenSSL import SSL
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


def norm_host(host):
    return (host or "").lower().rstrip(".").strip("[]")


def split_authority(value):
    value = value.strip()
    if value.startswith("["):
        host, _, rest = value[1:].partition("]")
        port = rest[1:] if rest.startswith(":") else ""
    elif value.count(":") == 1:
        host, _, port = value.partition(":")
    else:
        host, port = value, ""
    return norm_host(host), int(port) if port.isdigit() else None


def literal_ip(host):
    return parse_ip(norm_host(host))


def local_addresses():
    """Every address assigned to one of the host's interfaces."""
    found = set()
    try:
        with open("/proc/self/net/fib_trie") as f:
            last = None
            for line in f:
                part = line.strip()
                if part.startswith("|--"):
                    last = part[3:].strip()
                elif part == "/32 host LOCAL" and last:
                    found.add(last)
    except OSError:
        pass
    try:
        with open("/proc/self/net/if_inet6") as f:
            for line in f:
                raw = line.split()[0]
                found.add(str(ipaddress.IPv6Address(int(raw, 16))))
    except (OSError, ValueError, IndexError):
        pass
    return found


NAT64 = ipaddress.ip_network("64:ff9b::/96")
COMPATIBLE = ipaddress.ip_network("::/96")


def parse_ip(ip):
    try:
        return ipaddress.ip_address(str(ip).split("%", 1)[0].strip("[]"))
    except ValueError:
        return None


def forms(address):
    """The address and every IPv4 address an IPv6 form of it carries, which may reach the same host."""
    found = {address}
    if isinstance(address, ipaddress.IPv6Address):
        found.update(a for a in (address.ipv4_mapped, address.sixtofour) if a)
        if address.teredo:
            found.update(address.teredo)
        if address in NAT64 or (address in COMPATIBLE and int(address) > 1):
            found.add(ipaddress.IPv4Address(int(address) & 0xFFFFFFFF))
    return found


def internal_address(ip):
    """Addresses that reach the host itself or cloud metadata, which no sandbox may reach through the proxy."""
    address = parse_ip(ip)
    if address is None:
        return False
    return any(a.is_loopback or a.is_link_local or a.is_unspecified or a.is_multicast for a in forms(address))


def socket_owner(peer, local):
    """The uid owning the IPv4 TCP socket bound at peer and connected to local, if any."""

    def hexaddr(addr):
        ip, port = addr[0], addr[1]
        return "%08X:%04X" % (struct.unpack("=I", socket.inet_aton(ip))[0], port)

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

    def bindings(self, host, port):
        return [b for b in self.config.get("inject", []) if any(entry_matches(p, host, port) for p in b["hosts"])]

    def inspected(self, host, port):
        return bool(self.bindings(host, port)) or any(
            entry_matches(p, host, port) for p in self.config.get("inspect", [])
        )

    def preview(self, sandbox):
        return (self.peers.get(sandbox) or {}).get("preview") or {}

    def allowed(self, sandbox, host, port):
        if self.bindings(host, port):
            return True
        if any(entry_matches(e, host, port) for e in self.config.get("allow", [])):
            return True
        now = time.time()
        for e in self.runtime:
            if (e.get("expires") is None or e["expires"] > now) and entry_matches(e["pattern"], host, port):
                return True
        preview = self.preview(sandbox)
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
        if not value or "\n" in value or "\r" in value:
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
        self.local_checked, self.local_cache = float("-inf"), set()
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

    def deny(self, flow, code, decision, message):
        flow.metadata["agent"]["decision"] = decision
        flow.response = http.Response.make(code, b"agent-broker: " + message + b"\n")

    def http_connect(self, flow: http.HTTPFlow):
        self.policy.refresh(self.emit)
        client = flow.client_conn
        sandbox = self.identify(client)
        host, port = norm_host(flow.request.host), flow.request.port
        decision, ok = self.decide(sandbox, host, port)
        client.agent_target = (host, port)
        client.agent_decision = decision
        self.emit({"sandbox": sandbox, "host": host, "port": port, "method": "CONNECT", "decision": decision})
        if not ok:
            flow.response = http.Response.make(403, b"agent-broker: egress to this host is not allowed\n")

    def local(self):
        now = time.monotonic()
        if now - self.local_checked > 30:
            self.local_checked, self.local_cache = now, local_addresses()
        return self.local_cache

    def refused(self, sandbox, ip, port):
        address = parse_ip(ip)
        if address is None or internal_address(ip):
            return True
        local = {a for text in self.local() if (p := parse_ip(text)) for a in forms(p)}
        if not forms(address) & local:
            return False
        preview = self.policy.preview(sandbox)
        own = parse_ip(preview.get("address") or "")
        return not (own is not None and address == own and port in preview.get("ports", []))

    async def resolve(self, host, port):
        infos = await asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM)
        return [info[4][0] for info in infos]

    async def server_connect(self, data):
        host, port = data.server.address
        sandbox = getattr(data.client, "agent_sandbox", None)
        literal = literal_ip(host)
        if literal is not None:
            addresses = [str(literal)]
        else:
            try:
                addresses = await self.resolve(host, port)
            except OSError as e:
                data.server.error = f"agent-broker: cannot resolve {host}: {e}"
                return
            addresses.sort(key=lambda a: ":" in a)
        if not addresses:
            data.server.error = f"agent-broker: cannot resolve {host}"
            return
        if not self.allow_internal and any(self.refused(sandbox, a, port) for a in addresses):
            data.server.error = "agent-broker: the host's own and link-local addresses are not reachable"
            self.emit({"sandbox": sandbox, "host": host, "port": port, "decision": "deny-internal"})
            return
        if literal is None:
            if data.server.sni is None:
                data.server.sni = host
            data.server.address = (addresses[0], port)

    def next_layer(self, nextlayer):
        context = nextlayer.context
        target = getattr(context.client, "agent_target", None)
        address = context.server.address
        if not target or not address or address[1] in WEB_PORTS:
            return
        if not self.policy.inspected(target[0], target[1]):
            nextlayer.layer = layers.TCPLayer(context, ignore=True)

    def tls_clienthello(self, data):
        client = data.context.client
        target = getattr(client, "agent_target", None)
        if target is None:
            client.agent_refuse_tls = True
            return
        sni = norm_host(data.client_hello.sni)
        if sni and sni != target[0]:
            client.agent_refuse_tls = True
            self.emit(
                {
                    "sandbox": getattr(client, "agent_sandbox", None),
                    "host": target[0],
                    "port": target[1],
                    "sni": sni[:255],
                    "decision": "deny-sni",
                }
            )
            return
        if not self.policy.inspected(target[0], target[1]):
            data.ignore_connection = True

    def tls_start_client(self, data):
        if getattr(data.context.client, "agent_refuse_tls", False):
            # A context without a certificate fails the handshake; tlsconfig only fills in an unset ssl_conn.
            data.ssl_conn = SSL.Connection(SSL.Context(SSL.TLS_SERVER_METHOD))
            data.ssl_conn.set_accept_state()

    def requestheaders(self, flow: http.HTTPFlow):
        if flow.request.method == "CONNECT":
            return
        self.policy.refresh(self.emit)
        flow.request.headers.pop("Proxy-Authorization", None)
        client = flow.client_conn
        sandbox = self.identify(client)
        target = getattr(client, "agent_target", None)
        host, port = target if target else (norm_host(flow.request.host), flow.request.port)
        flow.metadata["agent"] = {"sandbox": sandbox, "decision": None, "injected": None, "host": host, "port": port}
        if target is None and flow.request.scheme == "https":
            self.deny(flow, 403, "deny-absolute-https", b"send https through CONNECT")
            return
        authority = flow.request.host_header
        if authority is not None:
            named, named_port = split_authority(authority)
            if named != host or (named_port is not None and named_port != port):
                self.deny(flow, 421, "deny-misdirected", b"the Host header doesn't match the connection's target")
                return
        decision, ok = self.decide(sandbox, host, port)
        flow.metadata["agent"]["decision"] = decision
        if not ok:
            self.deny(flow, 403, decision, b"egress to this host is not allowed")
            return
        bindings = self.policy.bindings(host, port)
        if not bindings:
            return
        if flow.request.scheme != "https":
            self.deny(flow, 403, "deny-cleartext", b"credentials are only sent over https")
            return
        values = [(b, self.policy.secret(b)) for b in bindings]
        for b, _ in values:
            flow.request.headers.pop(b.get("header", "Authorization"), None)
        if any(value is None for _, value in values):
            flow.metadata["agent"]["decision"] = "deny-missing-secret"
            flow.response = http.Response.make(503, MISSING, {"Content-Type": "application/json"})
            return
        for b, value in values:
            flow.request.headers[b.get("header", "Authorization")] = b.get("format", "Bearer {}").replace("{}", value)
        flow.metadata["agent"]["injected"] = ",".join(b["name"] for b in bindings)

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
                "host": agent.get("host", norm_host(flow.request.host)),
                "port": agent.get("port", flow.request.port),
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
