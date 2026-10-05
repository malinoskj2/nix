"""Hyprland event-driven presentation limiter; loss of IPC fails open."""

import os
from pathlib import Path
import re
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time

from game_background_limit import EVENTS, hypr, physical_signature


def birth(pid):
    try:
        text = Path(f"/proc/{pid}/stat").read_text()
        return int(text[text.rindex(")") + 2 :].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def environment_token(pid):
    try:
        for value in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
            if value.startswith(b"GAME_BACKGROUND_LIMIT_ID="):
                return value.partition(b"=")[2].decode("ascii")
    except (OSError, UnicodeError):
        pass
    return None


class Client:
    def __init__(self, connection):
        self.connection = connection
        self.pid, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if uid != os.getuid():
            raise ValueError("foreign controller client")
        self.born = birth(self.pid)
        if self.born is None:
            raise ValueError("unavailable client identity")
        self.token = None
        self.buffer = b""
        self.command = None
        self.deadline = time.monotonic() + 2

    def read(self):
        data = self.connection.recv(128)
        if not data:
            raise OSError("client disconnected")
        self.buffer += data
        if len(self.buffer) > 128:
            raise ValueError("oversized registration")
        if b"\n" in self.buffer:
            if self.token is not None or not re.fullmatch(rb"v1 [0-9a-f]{32}\n", self.buffer):
                raise ValueError("invalid registration")
            self.token = self.buffer[3:-1].decode("ascii")
            self.buffer = b""
            # No focus data means no limit, including during registration.
            self.set_background(False)
            return True
        return False

    def set_background(self, background):
        command = b"B" if background else b"F"
        if self.token and command != self.command:
            if self.connection.send(command) != 1:
                raise OSError("incomplete control write")
            self.command = command

    def owns(self, window):
        pid = window.get("pid")
        return (pid == self.pid and birth(pid) == self.born) or (
            self.token is not None and environment_token(pid) == self.token
        )


def reconcile(signature, clients):
    windows = hypr(signature, "clients")
    active = hypr(signature, "activewindow")
    groups = {}
    for client in clients.values():
        if client.token:
            groups.setdefault(client.token, []).append(client)
    for members in groups.values():
        owned = [window for window in windows if any(client.owns(window) for client in members)]
        focused = any(window["address"] == active.get("address") for window in owned)
        for client in members:
            client.set_background(bool(owned) and not focused)


def main():
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "game-background-limit"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = Path(os.environ.get("GAME_BACKGROUND_LIMIT_SOCKET", cache / "control.sock"))
    selector = selectors.DefaultSelector()
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # Do not unlink another controller's live endpoint.
    if path.exists():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.connect(str(path))
            except OSError:
                path.unlink()
            else:
                raise OSError("background limiter controller already running")
    server.bind(str(path))
    path.chmod(0o600)
    server.listen(64)
    server.setblocking(False)
    selector.register(server, selectors.EVENT_READ, "server")
    wake_read, wake_write = socket.socketpair()
    wake_read.setblocking(False)
    wake_write.setblocking(False)
    selector.register(wake_read, selectors.EVENT_READ, "signal")
    clients = {}
    events = None
    signature = None
    buffered = b""
    retry = 0
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
        try:
            wake_write.send(b"\0")
        except OSError:
            pass

    def disconnect_events():
        nonlocal events, signature, retry, buffered
        if events is not None:
            selector.unregister(events)
            events.close()
        events, signature, buffered = None, None, b""
        retry = time.monotonic() + 1
        for connection, client in list(clients.items()):
            try:
                client.set_background(False)
            except OSError:
                remove_client(connection)

    def remove_client(connection):
        selector.unregister(connection)
        connection.close()  # EOF wakes the engine immediately and clears its cap.
        clients.pop(connection, None)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            if events is None and time.monotonic() >= retry:
                try:
                    signature = physical_signature()
                    candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    try:
                        candidate.settimeout(2)
                        candidate.connect(
                            str(Path(os.environ["XDG_RUNTIME_DIR"]) / "hypr" / signature / ".socket2.sock")
                        )
                    except Exception:
                        candidate.close()
                        raise
                    candidate.setblocking(False)
                    events = candidate
                    selector.register(events, selectors.EVENT_READ, "hypr")
                    reconcile(signature, clients)
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                    print(f"game-background-limit: uncapped: {error}", file=sys.stderr)
                    disconnect_events()
            changed = False
            pending = [client.deadline for client in clients.values() if not client.token]
            timeout = None if events is not None else max(0, retry - time.monotonic())
            if pending:
                remaining = max(0, min(pending) - time.monotonic())
                timeout = remaining if timeout is None else min(timeout, remaining)
            ready = selector.select(timeout)
            if stopping:
                break
            for key, _ in ready:
                if key.data == "server":
                    connection, _ = server.accept()
                    connection.setblocking(False)
                    try:
                        if len(clients) >= 256:
                            raise ValueError("too many limiter clients")
                        client = Client(connection)
                        clients[connection] = client
                        selector.register(connection, selectors.EVENT_READ, "client")
                    except (OSError, ValueError):
                        connection.close()
                elif key.data == "client":
                    if key.fileobj not in clients:
                        continue
                    try:
                        changed |= clients[key.fileobj].read()
                    except (OSError, ValueError):
                        remove_client(key.fileobj)
                        changed = True
                elif key.data == "hypr":
                    try:
                        data = events.recv(65536)
                        if not data:
                            raise OSError("Hyprland disconnected")
                        buffered += data
                        if len(buffered) > 1024 * 1024:
                            raise ValueError("oversized Hyprland event")
                        lines = buffered.split(b"\n")
                        buffered = lines.pop()
                        changed |= any(line.partition(b">>")[0].decode() in EVENTS for line in lines)
                    except (OSError, ValueError):
                        disconnect_events()
            for connection, client in list(clients.items()):
                if not client.token and time.monotonic() >= client.deadline:
                    remove_client(connection)
            if changed and events is not None:
                try:
                    reconcile(signature, clients)
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    disconnect_events()
    finally:
        for connection in list(clients):
            remove_client(connection)
        if events is not None:
            events.close()
        server.close()
        wake_read.close()
        wake_write.close()
        selector.close()
        path.unlink(missing_ok=True)
    return 0
