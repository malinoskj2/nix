#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import select
import socket
import socketserver
import struct
import sys
import threading
from typing import NamedTuple
from urllib.parse import parse_qsl, urlencode

MAX_HEAD = 65536
MAX_BODY = 8 * 1024 * 1024
READ_SIZE = 65536
MAX_CONNECTIONS = 32
IDLE_TIMEOUT = 5
CONNECT_TIMEOUT = 2


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


def translate_process(value: str, peer: int) -> str:
    # Orca checks the agent's pid on the host to tell whether it has exited, but
    # the hook reports the container's pid for it. Untranslatable means unknown.
    try:
        process = json.loads(value)
        pid = host_pid(peer, int(process["pid"]))
        if pid is not None:
            process["pid"] = pid
            return json.dumps(process, separators=(",", ":"))
    except (ValueError, TypeError, KeyError):
        pass
    return ""


def translate_agent_process(head: bytes, peer: int) -> bytes:
    lines = head.split(b"\r\n")
    for index, line in enumerate(lines):
        name, sep, value = line.partition(b":")
        if not sep or name.strip().lower() != b"x-orca-agent-process":
            continue
        lines[index] = b"X-Orca-Agent-Process: " + translate_process(value.decode(errors="replace"), peer).encode()
    return b"\r\n".join(lines)


def read_head(sock: socket.socket) -> bytes | None:
    data = b""
    while b"\r\n\r\n" not in data:
        if len(data) > MAX_HEAD:
            return None
        chunk = sock.recv(READ_SIZE)
        if not chunk:
            return None
        data += chunk
    return data


class TranscriptRoot(NamedTuple):
    """Transcripts the agent writes under container, which Orca reads under host."""

    keys: tuple[str, ...]
    container: Path
    host: Path


def translate_transcript(body: bytes, content_type: str, root: TranscriptRoot, peer: int | None = None) -> bytes:
    """Translate the agent's transcript field, and a form's agent process, for this launch's mounts."""

    def translate(payload):
        if not isinstance(payload, dict) or root.container == root.host:
            return False
        changed = False
        for key in root.keys:
            if not isinstance(payload.get(key), str):
                continue
            try:
                relative = Path(payload[key]).relative_to(root.container)
            except ValueError:
                continue
            if ".." in relative.parts:
                continue
            payload[key] = str(root.host / relative)
            changed = True
        return changed

    try:
        if content_type == "application/json":
            payload = json.loads(body)
            if translate(payload):
                return json.dumps(payload, separators=(",", ":")).encode()
        elif content_type == "application/x-www-form-urlencoded":
            fields = parse_qsl(body.decode(), keep_blank_values=True)
            changed = False
            for index, (key, value) in enumerate(fields):
                if key == "payload":
                    payload = json.loads(value)
                    if translate(payload):
                        fields[index] = (key, json.dumps(payload, separators=(",", ":")))
                        changed = True
                elif key == "agentProcess" and value and peer is not None:
                    fields[index] = (key, translate_process(value, peer))
                    changed = True
            if changed:
                return urlencode(fields).encode()
    except (ValueError, UnicodeError):
        pass
    return body


def translate_request(
    sock: socket.socket, head: bytes, body: bytes, roots: dict[bytes, TranscriptRoot], peer: int | None = None
) -> bytes:
    lines = head.split(b"\r\n")
    request = lines[0].split()[:2]
    root = roots.get(request[1]) if len(request) == 2 and request[0] == b"POST" else None
    if root is None:
        return head + b"\r\n\r\n" + body
    headers = {}
    for line in lines[1:]:
        name, sep, value = line.partition(b":")
        if sep:
            headers[name.strip().lower()] = value.strip()
    # curl's hook transports send a Content-Length. Leave other framing alone.
    if b"transfer-encoding" in headers or b"content-length" not in headers:
        return head + b"\r\n\r\n" + body
    length = int(headers[b"content-length"])
    if not 0 <= length <= MAX_BODY:
        raise ValueError("hook body exceeds limit")
    if headers.get(b"expect", b"").lower() == b"100-continue":
        sock.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
    while len(body) < length:
        chunk = sock.recv(min(READ_SIZE, length - len(body)))
        if not chunk:
            raise ValueError("incomplete hook body")
        body += chunk
    content_type = headers.get(b"content-type", b"").split(b";", 1)[0].strip().decode("ascii")
    translated = translate_transcript(body[:length], content_type, root, peer)
    lines = [line for line in lines if line.partition(b":")[0].strip().lower() not in (b"content-length", b"expect")]
    lines.append(b"Content-Length: " + str(len(translated)).encode())
    return b"\r\n".join(lines) + b"\r\n\r\n" + translated + body[length:]


def relay(client: socket.socket, upstream: socket.socket) -> None:
    sockets = [client, upstream]
    while sockets:
        readable, _, _ = select.select(sockets, [], [], IDLE_TIMEOUT)
        if not readable:
            return
        for source in readable:
            target = upstream if source is client else client
            try:
                data = source.recv(READ_SIZE)
                if data:
                    target.sendall(data)
                else:
                    sockets.remove(source)
                    target.shutdown(socket.SHUT_WR)
            except OSError:
                return


class HookServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = MAX_CONNECTIONS

    def __init__(self, socket_path: str, endpoint_path: str, fallback_port: int, roots: dict[bytes, TranscriptRoot]):
        self.endpoint_path = endpoint_path
        self.fallback_port = fallback_port
        self.roots = roots
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(socket_path, HookHandler)
        os.chmod(socket_path, 0o600)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        # The handler thread releases the slot when it finishes, so release it
        # here only if that thread never started.
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

    def current_endpoint(self) -> tuple[int, bytes | None]:
        """The desktop's live hook port and token, which change when Orca restarts."""
        port, token = self.fallback_port, None
        try:
            with open(self.endpoint_path, encoding="ascii") as endpoint:
                for line in endpoint:
                    if match := re.fullmatch(r"ORCA_AGENT_HOOK_PORT=([0-9]{1,5})\n?", line):
                        if 0 < int(match[1]) <= 65535:
                            port = int(match[1])
                    elif match := re.fullmatch(r"ORCA_AGENT_HOOK_TOKEN=([A-Za-z0-9._~+/=-]+)\n?", line):
                        token = match[1].encode()
        except (OSError, UnicodeError):
            pass
        return port, token


def replace_hook_token(head: bytes, token: bytes | None) -> bytes:
    if token is None:
        return head
    lines = head.split(b"\r\n")
    for index, line in enumerate(lines):
        name, sep, _ = line.partition(b":")
        if sep and name.strip().lower() == b"x-orca-agent-hook-token":
            lines[index] = b"X-Orca-Agent-Hook-Token: " + token
    return b"\r\n".join(lines)


class HookHandler(socketserver.BaseRequestHandler):
    def handle(self):
        server: HookServer = self.server
        try:
            self.request.settimeout(IDLE_TIMEOUT)
            data = read_head(self.request)
            if data is None:
                return
            head, _, body = data.partition(b"\r\n\r\n")
            peer = peer_pid(self.request)
            head = translate_agent_process(head, peer)
            port, token = server.current_endpoint()
            head = replace_hook_token(head, token)
            data = translate_request(self.request, head, body, server.roots, peer)
            self.request.settimeout(None)
            upstream = socket.create_connection(("127.0.0.1", port), timeout=CONNECT_TIMEOUT)
        except (OSError, ValueError):
            return
        with upstream:
            try:
                upstream.sendall(data)
            except OSError:
                return
            relay(self.request, upstream)


def transcript_roots(codex_container: str, codex_host: str, gemini_container: str, gemini_host: str):
    return {
        b"/hook/codex": TranscriptRoot(
            ("transcript_path",), Path(codex_container) / "sessions", Path(codex_host) / "sessions"
        ),
        b"/hook/antigravity": TranscriptRoot(
            ("transcriptPath", "transcript_path"), Path(gemini_container), Path(gemini_host)
        ),
    }


if __name__ == "__main__":
    if len(sys.argv) != 8:
        raise SystemExit(
            "usage: hook-proxy <socket> <endpoint-file> <fallback-port> <container-codex-home> <host-codex-home>"
            " <container-gemini-home> <host-gemini-home>"
        )
    with HookServer(sys.argv[1], sys.argv[2], int(sys.argv[3]), transcript_roots(*sys.argv[4:])) as proxy:
        proxy.serve_forever(poll_interval=0.2)
