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

REGISTRATION_LIMIT = 128
REGISTRATION_TIMEOUT = 2
MAX_CLIENTS = 256
EVENT_READ_SIZE = 65536
EVENT_BUFFER_LIMIT = 1024 * 1024
RETRY_DELAY = 1
HYPRLAND_ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


def start_time(pid):
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
        self.start_time = start_time(self.pid)
        if self.start_time is None:
            raise ValueError("unavailable client identity")
        self.token = None
        self.buffer = b""
        self.command = None
        self.deadline = time.monotonic() + REGISTRATION_TIMEOUT

    def read(self):
        data = self.connection.recv(REGISTRATION_LIMIT)
        if not data:
            raise OSError("client disconnected")
        self.buffer += data
        if len(self.buffer) > REGISTRATION_LIMIT:
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
        return (pid == self.pid and start_time(pid) == self.start_time) or (
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


def control_path():
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "game-background-limit"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    return Path(os.environ.get("GAME_BACKGROUND_LIMIT_SOCKET", cache / "control.sock"))


def listen(path):
    # Do not unlink another controller's live endpoint.
    if path.exists():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            try:
                probe.connect(str(path))
            except OSError:
                path.unlink()
            else:
                raise OSError("background limiter controller already running")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    path.chmod(0o600)
    server.listen(64)
    server.setblocking(False)
    return server


class Controller:
    def __init__(self, path):
        self.path = path
        self.server = listen(path)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.server, selectors.EVENT_READ, self.accept)
        self.wake_read, self.wake_write = socket.socketpair()
        self.wake_read.setblocking(False)
        self.wake_write.setblocking(False)
        self.selector.register(self.wake_read, selectors.EVENT_READ, lambda _wake: False)
        self.clients = {}
        self.events = None
        self.signature = None
        self.buffered = b""
        self.retry = 0
        self.stopping = False

    def stop(self, _signum, _frame):
        self.stopping = True
        try:
            self.wake_write.send(b"\0")
        except OSError:
            pass

    def connect_events(self):
        try:
            self.signature = physical_signature()
            candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                candidate.settimeout(2)
                candidate.connect(str(Path(os.environ["XDG_RUNTIME_DIR"]) / "hypr" / self.signature / ".socket2.sock"))
            except Exception:
                candidate.close()
                raise
            candidate.setblocking(False)
            self.events = candidate
            self.selector.register(self.events, selectors.EVENT_READ, self.read_events)
            reconcile(self.signature, self.clients)
        except HYPRLAND_ERRORS as error:
            print(f"game-background-limit: uncapped: {error}", file=sys.stderr)
            self.disconnect_events()

    def disconnect_events(self):
        if self.events is not None:
            self.selector.unregister(self.events)
            self.events.close()
        self.events, self.signature, self.buffered = None, None, b""
        self.retry = time.monotonic() + RETRY_DELAY
        for connection, client in list(self.clients.items()):
            try:
                client.set_background(False)
            except OSError:
                self.remove_client(connection)

    def remove_client(self, connection):
        self.selector.unregister(connection)
        # EOF wakes the engine immediately and clears its cap.
        connection.close()
        self.clients.pop(connection, None)

    def accept(self, server):
        connection, _ = server.accept()
        connection.setblocking(False)
        try:
            if len(self.clients) >= MAX_CLIENTS:
                raise ValueError("too many limiter clients")
            self.clients[connection] = Client(connection)
            self.selector.register(connection, selectors.EVENT_READ, self.read_client)
        except (OSError, ValueError):
            connection.close()
        return False

    def read_client(self, connection):
        if connection not in self.clients:
            return False
        try:
            return self.clients[connection].read()
        except (OSError, ValueError):
            self.remove_client(connection)
            return True

    def read_events(self, events):
        try:
            data = events.recv(EVENT_READ_SIZE)
            if not data:
                raise OSError("Hyprland disconnected")
            self.buffered += data
            if len(self.buffered) > EVENT_BUFFER_LIMIT:
                raise ValueError("oversized Hyprland event")
            lines = self.buffered.split(b"\n")
            self.buffered = lines.pop()
            return any(line.partition(b">>")[0].decode() in EVENTS for line in lines)
        except (OSError, ValueError):
            self.disconnect_events()
            return False

    def timeout(self):
        pending = [client.deadline for client in self.clients.values() if not client.token]
        timeout = None if self.events is not None else max(0, self.retry - time.monotonic())
        if pending:
            remaining = max(0, min(pending) - time.monotonic())
            timeout = remaining if timeout is None else min(timeout, remaining)
        return timeout

    def expire_registrations(self):
        for connection, client in list(self.clients.items()):
            if not client.token and time.monotonic() >= client.deadline:
                self.remove_client(connection)

    def run(self):
        try:
            while not self.stopping:
                if self.events is None and time.monotonic() >= self.retry:
                    self.connect_events()
                ready = self.selector.select(self.timeout())
                if self.stopping:
                    break
                changed = False
                for key, _ in ready:
                    changed |= key.data(key.fileobj)
                self.expire_registrations()
                if changed and self.events is not None:
                    try:
                        reconcile(self.signature, self.clients)
                    except HYPRLAND_ERRORS:
                        self.disconnect_events()
        finally:
            self.close()

    def close(self):
        for connection in list(self.clients):
            self.remove_client(connection)
        if self.events is not None:
            self.events.close()
        self.server.close()
        self.wake_read.close()
        self.wake_write.close()
        self.selector.close()
        self.path.unlink(missing_ok=True)


def main():
    controller = Controller(control_path())
    signal.signal(signal.SIGTERM, controller.stop)
    signal.signal(signal.SIGINT, controller.stop)
    controller.run()
    return 0
