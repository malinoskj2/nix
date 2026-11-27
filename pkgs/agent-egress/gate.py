import argparse
import asyncio
import ipaddress
import json
import os
import pwd
import re
import shutil
import signal
import socket
import struct
import sys
import time

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
POOL = ipaddress.ip_network("127.77.0.0/16")
MAX_LINE = 4096


def log(**record):
    record = {"ts": round(time.time(), 3), **record}
    sys.stdout.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def peer_uid(sock):
    data = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", data)[1]


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def make_dir(path):
    # The group and setgid come from the broker's socket directory; RestrictSUIDSGID refuses a
    # chmod that would keep them.
    try:
        os.mkdir(path, 0o750)
    except FileExistsError:
        pass


def atomic_json(path, data, mode=0o644):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


class Gate:
    def __init__(self, root, proxy, clients, ca, trust=None):
        self.root = root
        self.trust = trust
        self.proxy = proxy
        self.clients = clients
        self.ca = ca
        self.registry_path = os.path.join(root, "registry.json")
        self.peers_path = os.path.join(root, "peers.json")
        self.sandbox_root = os.path.join(root, "sandbox")
        self.entries = {}
        self.servers = {}
        self.lock = asyncio.Lock()

    def allocate(self):
        used = {e["address"] for e in self.entries.values()}
        for index, address in enumerate(POOL.hosts()):
            if index == 0:
                continue
            if str(address) not in used:
                return str(address)
        raise RuntimeError("no free egress addresses")

    def save(self):
        atomic_json(self.registry_path, self.entries, 0o600)
        peers = {name: {"address": e["address"], "preview": e.get("preview") or {}} for name, e in self.entries.items()}
        atomic_json(self.peers_path, peers)

    def directory(self, name):
        return os.path.join(self.sandbox_root, name)

    async def listen(self, name):
        entry = self.entries[name]
        directory = self.directory(name)
        make_dir(directory)
        if os.path.exists(self.ca):
            with open(self.ca, "rb") as f:
                ca = f.read()
            self.publish(directory, "ca.pem", ca)
            if self.trust:
                with open(self.trust, "rb") as f:
                    self.publish(directory, "ca-bundle.crt", f.read().rstrip(b"\n") + b"\n" + ca)
        path = os.path.join(directory, "proxy.sock")
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = await asyncio.start_unix_server(lambda r, w: self.forward(entry, r, w), path=path)
        os.chmod(path, 0o660)
        self.servers[name] = server

    @staticmethod
    def publish(directory, name, data):
        target = os.path.join(directory, name)
        with open(target + ".tmp", "wb") as f:
            f.write(data)
        os.chmod(target + ".tmp", 0o644)
        os.replace(target + ".tmp", target)

    async def forward(self, entry, reader, writer):
        try:
            up_reader, up_writer = await asyncio.open_connection(
                self.proxy[0], self.proxy[1], local_addr=(entry["address"], 0)
            )
        except OSError as error:
            log(event="proxy-unreachable", sandbox=entry["name"], error=str(error))
            writer.close()
            return

        async def pipe(src, dst):
            try:
                while data := await src.read(65536):
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, asyncio.IncompleteReadError):
                pass
            finally:
                try:
                    dst.write_eof()
                except (OSError, RuntimeError):
                    dst.close()

        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
        for w in (writer, up_writer):
            w.close()

    async def drop(self, name):
        server = self.servers.pop(name, None)
        if server:
            server.close()
        self.entries.pop(name, None)
        shutil.rmtree(self.directory(name), ignore_errors=True)

    async def control(self, reader, writer):
        sock = writer.get_extra_info("socket")
        try:
            uid = peer_uid(sock)
            line = await reader.readline()
            if len(line) > MAX_LINE:
                raise ValueError("request too long")
            request = json.loads(line or b"{}")
            if uid != 0 and uid not in self.clients:
                raise PermissionError("this user may not register sandboxes")
            reply = await self.handle(request, uid)
        except (ValueError, PermissionError, RuntimeError, KeyError, TypeError) as error:
            reply = {"ok": False, "error": str(error)}
        writer.write((json.dumps(reply) + "\n").encode())
        await writer.drain()
        writer.close()

    async def handle(self, request, uid):
        op = request.get("op")
        name = request.get("name", "")
        if op == "exception":
            log(event="exception", sandbox=str(name)[:128], reason=str(request.get("reason", ""))[:200], uid=uid)
            return {"ok": True}
        if not isinstance(name, str) or not NAME.match(name):
            raise ValueError("invalid sandbox name")
        async with self.lock:
            await self.reap()
            if op == "register":
                pid = request.get("pid")
                if not isinstance(pid, int) or pid <= 1:
                    raise ValueError("register needs the launcher's pid")
                preview = request.get("preview") or {}
                ports = [p for p in preview.get("ports", []) if isinstance(p, int) and 0 < p < 65536]
                address = preview.get("address") if isinstance(preview.get("address"), str) else None
                if name in self.entries:
                    await self.drop(name)
                self.entries[name] = {
                    "name": name,
                    "address": self.allocate(),
                    "pid": pid,
                    "uid": uid,
                    "preview": {"address": address, "ports": ports[:32]} if address else {},
                    "since": int(time.time()),
                }
                await self.listen(name)
                self.save()
                log(event="register", sandbox=name, address=self.entries[name]["address"], uid=uid)
                return {"ok": True, "dir": self.directory(name), "address": self.entries[name]["address"]}
            if op == "unregister":
                if name in self.entries:
                    await self.drop(name)
                    self.save()
                    log(event="unregister", sandbox=name, uid=uid)
                return {"ok": True}
        raise ValueError(f"unknown op {op!r}")

    async def reap(self):
        for name, entry in list(self.entries.items()):
            if not pid_alive(entry["pid"]):
                await self.drop(name)
                log(event="reap", sandbox=name)

    async def reap_loop(self):
        while True:
            await asyncio.sleep(60)
            async with self.lock:
                before = len(self.entries)
                await self.reap()
                if len(self.entries) != before:
                    self.save()

    async def run(self):
        make_dir(self.sandbox_root)
        try:
            with open(self.registry_path) as f:
                self.entries = json.load(f)
        except (OSError, ValueError):
            self.entries = {}
        for name in os.listdir(self.sandbox_root):
            if name not in self.entries:
                shutil.rmtree(self.directory(name), ignore_errors=True)
        await self.reap()
        for name in list(self.entries):
            await self.listen(name)
        self.save()
        control_path = os.path.join(self.root, "control.sock")
        try:
            os.unlink(control_path)
        except FileNotFoundError:
            pass
        control = await asyncio.start_unix_server(self.control, path=control_path, limit=MAX_LINE * 2)
        # Launchers in sessions that predate their agent-broker-clients membership must still connect;
        # the peer's uid is checked instead.
        os.chmod(control_path, 0o666)
        log(event="start", sandboxes=len(self.entries))
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        reaper = asyncio.create_task(self.reap_loop())
        await stop.wait()
        reaper.cancel()
        control.close()
        for server in self.servers.values():
            server.close()


def uids(names):
    result = set()
    for name in names:
        try:
            result.add(pwd.getpwnam(name).pw_uid)
        except KeyError:
            log(event="unknown-client", user=name)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="Per-sandbox egress sockets in front of the broker proxy")
    parser.add_argument("--root", default=os.environ.get("AGENT_BROKER_SOCKET_DIR", "/run/agent-broker/egress-gate"))
    parser.add_argument("--proxy", default="127.0.0.1:3128")
    parser.add_argument("--ca", default="/run/agent-broker/egress-proxy/ca.pem")
    parser.add_argument("--trust", help="CA bundle that sandboxes get with the broker CA appended")
    parser.add_argument("--client", action="append", default=[])
    args = parser.parse_args(argv)
    host, _, port = args.proxy.rpartition(":")
    gate = Gate(args.root, (host, int(port)), uids(args.client), args.ca, args.trust)
    asyncio.run(gate.run())


if __name__ == "__main__":
    main()
