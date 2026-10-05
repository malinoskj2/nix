#!/usr/bin/env python3
"""Forward one private Unix socket to Orca's current loopback hook port."""

import os
import re
import select
import socket
import socketserver
import sys
import threading


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
            upstream = socket.create_connection(("127.0.0.1", server.current_port()), timeout=2)
        except OSError:
            return
        with upstream:
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
