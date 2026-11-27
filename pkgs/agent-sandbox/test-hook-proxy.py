#!/usr/bin/env python3
"""Verify transcript mapping and HTTP framing without containers or Orca."""

import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qsl, urlencode

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("hook_proxy", Path(__file__).with_name("hook-proxy.py"))
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)

CONTAINER = Path("/home/test/.codex")
HOST = Path("/data/agent-sandbox/home/.codex")
TRANSCRIPT = "sessions/2026/11/07/rollout-test.jsonl"
GEMINI_CONTAINER = Path("/home/test/.gemini")
GEMINI_HOST = Path("/data/agent-sandbox/home/.gemini")
AGY_TRANSCRIPT = "antigravity-cli/brain/6bba92d4/transcript.jsonl"
ROOTS = proxy.transcript_roots(str(CONTAINER), str(HOST), str(GEMINI_CONTAINER), str(GEMINI_HOST))
CODEX = ROOTS[b"/hook/codex"]
SAME = proxy.TranscriptRoot(CODEX.keys, CODEX.container, CODEX.container)


class TranscriptTest(unittest.TestCase):
    def payload(self, path=None):
        return {"transcript_path": path or str(CONTAINER / TRANSCRIPT), "prompt": "keep café unchanged"}

    def test_private_home_mapping_does_not_depend_on_file_existence(self):
        # Mapping follows the mount, never whichever copy happens to exist.
        result = proxy.translate_transcript(json.dumps(self.payload()).encode(), "application/json", CODEX)
        self.assertEqual(json.loads(result), self.payload(str(HOST / TRANSCRIPT)))

    def test_explicit_account_mount_stays_byte_for_byte_unchanged(self):
        body = json.dumps(self.payload()).encode()
        self.assertEqual(proxy.translate_transcript(body, "application/json", SAME), body)

    def test_other_paths_and_invalid_payloads_are_unchanged(self):
        for body in [b"not json", b"null", b"[]", b"{}", b'{"transcript_path":null}'] + [
            json.dumps(self.payload(path)).encode()
            for path in (
                "/another/account/" + TRANSCRIPT,
                str(CONTAINER / "sessions-other/file.jsonl"),
                str(CONTAINER / "sessions/../config.toml"),
                "relative/file.jsonl",
            )
        ]:
            with self.subTest(body=body):
                self.assertEqual(proxy.translate_transcript(body, "application/json", CODEX), body)

    def test_form_transport_preserves_metadata_and_prompt(self):
        body = urlencode([("paneKey", "pane+one"), ("payload", json.dumps(self.payload())), ("empty", "")]).encode()
        result = proxy.translate_transcript(body, "application/x-www-form-urlencoded", CODEX)
        fields = dict(parse_qsl(result.decode(), keep_blank_values=True))
        self.assertEqual(fields["paneKey"], "pane+one")
        self.assertEqual(fields["empty"], "")
        self.assertEqual(json.loads(fields["payload"]), self.payload(str(HOST / TRANSCRIPT)))

    def test_fragmented_request_updates_length_and_handles_expect_continue(self):
        body = json.dumps(self.payload(), ensure_ascii=False).encode()
        head = (
            b"POST /hook/codex HTTP/1.1\r\nContent-Type: application/json; charset=utf-8\r\n"
            b"X-Orca-Agent-Hook-Token: keep-token\r\nExpect: 100-continue\r\nContent-Length: " + str(len(body)).encode()
        )
        reader, writer = socket.socketpair()
        with reader, writer:
            reader.settimeout(2)
            writer.settimeout(2)
            errors = []

            def send():
                try:
                    self.assertEqual(writer.recv(1024), b"HTTP/1.1 100 Continue\r\n\r\n")
                    writer.sendall(body)
                except Exception as error:
                    errors.append(error)
                finally:
                    writer.shutdown(socket.SHUT_WR)

            thread = threading.Thread(target=send)
            thread.start()
            try:
                request = proxy.translate_request(reader, head, b"", ROOTS)
            finally:
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
        new_head, _, new_body = request.partition(b"\r\n\r\n")
        self.assertIn(b"Content-Length: " + str(len(new_body)).encode(), new_head)
        self.assertIn(b"X-Orca-Agent-Hook-Token: keep-token", new_head)
        self.assertNotIn(b"Expect:", new_head)
        self.assertEqual(json.loads(new_body), self.payload(str(HOST / TRANSCRIPT)))

    def test_antigravity_form_maps_transcript_and_agent_process(self):
        payload = {"hook_event_name": "PreInvocation", "transcriptPath": str(GEMINI_CONTAINER / AGY_TRANSCRIPT)}
        process = json.dumps({"pid": 7, "startTime": "x"})
        body = urlencode([("paneKey", "p"), ("agentProcess", process), ("payload", json.dumps(payload))]).encode()
        head = (
            b"POST /hook/antigravity HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\n"
            b"Content-Length: " + str(len(body)).encode()
        )
        original = proxy.host_pid
        proxy.host_pid = lambda peer, pid: 4242 if (peer, pid) == (99, 7) else None
        try:
            request = proxy.translate_request(None, head, body, ROOTS, 99)
        finally:
            proxy.host_pid = original
        fields = dict(parse_qsl(request.partition(b"\r\n\r\n")[2].decode(), keep_blank_values=True))
        self.assertEqual(fields["paneKey"], "p")
        self.assertEqual(json.loads(fields["agentProcess"]), {"pid": 4242, "startTime": "x"})
        self.assertEqual(json.loads(fields["payload"])["transcriptPath"], str(GEMINI_HOST / AGY_TRANSCRIPT))

    def test_untranslatable_form_agent_process_is_cleared(self):
        body = urlencode([("agentProcess", json.dumps({"pid": 7}))]).encode()
        result = proxy.translate_transcript(body, "application/x-www-form-urlencoded", CODEX, 99)
        self.assertEqual(dict(parse_qsl(result.decode(), keep_blank_values=True))["agentProcess"], "")

    def test_unrelated_requests_remain_unchanged(self):
        head = b"POST /hook/claude HTTP/1.1\r\nContent-Length: 2"
        self.assertEqual(proxy.translate_request(None, head, b"{}", ROOTS), head + b"\r\n\r\n{}")

    def test_relay_forwards_translated_transcript_and_returns_response(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(3)
            path = str(Path(directory) / "hook.sock")
            with proxy.HookServer(path, "", listener.getsockname()[1], ROOTS) as server:
                thread = threading.Thread(target=server.handle_request, daemon=True)
                thread.start()
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(3)
                    client.connect(path)
                    body = json.dumps(self.payload()).encode()
                    client.sendall(
                        b"POST /hook/codex HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
                        + str(len(body)).encode()
                        + b"\r\n\r\n"
                        + body
                    )
                    upstream, _ = listener.accept()
                    with upstream:
                        upstream.settimeout(3)
                        head, _, received = proxy.read_head(upstream).partition(b"\r\n\r\n")
                        length = int(head.split(b"Content-Length: ")[1].split(b"\r\n")[0])
                        while len(received) < length:
                            chunk = upstream.recv(length - len(received))
                            self.assertTrue(chunk)
                            received += chunk
                        self.assertEqual(json.loads(received), self.payload(str(HOST / TRANSCRIPT)))
                        response = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
                        upstream.sendall(response)
                        upstream.shutdown(socket.SHUT_WR)
                        client.shutdown(socket.SHUT_WR)
                        returned = b""
                        while chunk := client.recv(1024):
                            returned += chunk
                        self.assertEqual(returned, response)
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())

    def test_live_endpoint_replaces_port_and_token(self):
        head = b"POST /hook/claude HTTP/1.1\r\nX-Orca-Agent-Hook-Token: stale\r\nContent-Length: 2"
        with tempfile.TemporaryDirectory() as directory:
            endpoint = Path(directory) / "endpoint.env"
            endpoint.write_text("ORCA_AGENT_HOOK_PORT=4242\nORCA_AGENT_HOOK_TOKEN=fresh-1\nORCA_AGENT_HOOK_ENV=x\n")
            with proxy.HookServer(str(Path(directory) / "hook.sock"), str(endpoint), 1, ROOTS) as server:
                port, token = server.current_endpoint()
                self.assertEqual((port, token), (4242, b"fresh-1"))
                endpoint.unlink()
                self.assertEqual(server.current_endpoint(), (1, None))
        self.assertEqual(
            proxy.replace_hook_token(head, b"fresh-1"),
            b"POST /hook/claude HTTP/1.1\r\nX-Orca-Agent-Hook-Token: fresh-1\r\nContent-Length: 2",
        )
        self.assertEqual(proxy.replace_hook_token(head, None), head)

    def test_incomplete_and_oversized_bodies_are_rejected(self):
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.shutdown(socket.SHUT_WR)
            for length in (10, proxy.MAX_BODY + 1, -1):
                head = b"POST /hook/codex HTTP/1.1\r\nContent-Length: " + str(length).encode()
                with self.subTest(length=length), self.assertRaises(ValueError):
                    proxy.translate_request(reader, head, b"", ROOTS)


if __name__ == "__main__":
    unittest.main()
