#!/usr/bin/env python3
"""Forward one private Unix socket to Orca's current loopback hook port."""

import json
import os
import re
import select
import socket
import socketserver
import struct
import sys
import threading

MAX_HEAD = 65536


def peer_pid(sock: socket.socket) -> int:
    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", creds)[0]


def proc_status(pid: int) -> dict[str, str]:
    with open(f"/proc/{pid}/status", encoding="utf-8", errors="replace") as status:
        return dict(line.rstrip("\n").split(":\t", 1) for line in status if ":\t" in line)


def host_pid(peer: int, container_pid: int) -> int | None:
    """Find the hook client's ancestor whose container pid is container_pid."""
    pid = peer
    for _ in range(64):
        try:
            status = proc_status(pid)
        except OSError:
            return None
        ids = status.get("NSpid", "").split()
        if len(ids) < 2:
            return None
        if int(ids[-1]) == container_pid:
            return int(ids[0])
        pid = int(status.get("PPid", "0"))
    return None


def translate_agent_process(head: bytes, peer: int) -> bytes:
    # Orca checks the agent's pid on the host to tell whether it has exited, but
    # the hook reports the container's pid for it. Untranslatable means unknown.
    lines = head.split(b"\r\n")
    for index, line in enumerate(lines):
        name, sep, value = line.partition(b":")
        if not sep or name.strip().lower() != b"x-orca-agent-process":
            continue
        translated = b""
        try:
            process = json.loads(value)
            pid = host_pid(peer, int(process["pid"]))
            if pid is not None:
                process["pid"] = pid
                translated = json.dumps(process, separators=(",", ":")).encode()
        except (ValueError, TypeError, KeyError):
            pass
        lines[index] = b"X-Orca-Agent-Process: " + translated
    return b"\r\n".join(lines)


def read_head(sock: socket.socket) -> bytes | None:
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > MAX_HEAD:
            return None
        chunk = sock.recv(65536)
        if not chunk:
            return None
        data += chunk
    return data


class HookServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, socket_path: str, endpoint_path: str, fallback_port: int):
        self.endpoint_path = endpoint_path
        self.fallback_port = fallback_port
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(socket_path, HookHandler)
        os.chmod(socket_path, 0o600)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def current_port(self) -> int:
        try:
            with open(self.endpoint_path, encoding="ascii") as endpoint:
                for line in endpoint:
                    match = re.fullmatch(r"ORCA_AGENT_HOOK_PORT=([0-9]{1,5})\n?", line)
                    if match and 0 < int(match[1]) <= 65535:
                        return int(match[1])
        except OSError:
            pass
        return self.fallback_port


class HookHandler(socketserver.BaseRequestHandler):
    def handle(self):
        server: HookServer = self.server
        try:
            self.request.settimeout(5)
            data = read_head(self.request)
            if data is None:
                return
            head, _, body = data.partition(b"\r\n\r\n")
            data = translate_agent_process(head, peer_pid(self.request)) + b"\r\n\r\n" + body
            self.request.settimeout(None)
            upstream = socket.create_connection(("127.0.0.1", server.current_port()), timeout=2)
        except OSError:
            return
        with upstream:
            try:
                upstream.sendall(data)
            except OSError:
                return
            sockets = [self.request, upstream]
            while sockets:
                readable, _, _ = select.select(sockets, [], [], 5)
                if not readable:
                    return
                for source in readable:
                    target = upstream if source is self.request else self.request
                    try:
                        data = source.recv(65536)
                        if data:
                            target.sendall(data)
                        else:
                            sockets.remove(source)
                            target.shutdown(socket.SHUT_WR)
                    except OSError:
                        return


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: hook-proxy <socket> <endpoint-file> <fallback-port>")
    with HookServer(sys.argv[1], sys.argv[2], int(sys.argv[3])) as proxy:
        proxy.serve_forever(poll_interval=0.2)
