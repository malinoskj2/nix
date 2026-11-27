import datetime
import http.server
import ipaddress
import json
import os
import pwd
import secrets
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

HERE = os.path.dirname(os.path.abspath(__file__))
MITMDUMP = os.environ.get("MITMDUMP", "mitmdump")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def write_ca_and_leaf(directory):
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test public ca")])
    ca = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(ca_key, hashes.SHA256())
    )
    key = ec.generate_private_key(ec.SECP256R1())
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "upstream")]))
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName(
                [
                    x509.DNSName("localhost"),
                    x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                    x509.IPAddress(ipaddress.ip_address("127.0.0.2")),
                ]
            ),
            critical=False,
        )
        .sign(ca_key, hashes.SHA256())
    )
    pem = serialization.Encoding.PEM
    with open(f"{directory}/up-ca.pem", "wb") as f:
        f.write(ca.public_bytes(pem))
    with open(f"{directory}/up.pem", "wb") as f:
        f.write(leaf.public_bytes(pem))
    with open(f"{directory}/up.key", "wb") as f:
        f.write(key.private_bytes(pem, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))


class Echo(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    secret = ""

    def log_message(self, *args):
        pass

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        body = json.dumps(
            {
                "injected": auth == f"Bearer {self.secret}",
                "has_secret": self.secret in str(self.headers),
                "auth_len": len(auth),
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class Egress(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.d = cls.tmp.name
        write_ca_and_leaf(d)
        cls.secret = secrets.token_urlsafe(24)
        with open(f"{d}/token", "w") as f:
            f.write(cls.secret + "\n")
        Echo.secret = cls.secret
        cls.up_port = free_port()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(f"{d}/up.pem", f"{d}/up.key")
        cls.upstream = Server(("0.0.0.0", cls.up_port), Echo)
        cls.upstream.socket = ctx.wrap_socket(cls.upstream.socket, server_side=True)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()

        banner = socket.socket()
        banner.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        banner.bind(("127.0.0.1", 0))
        banner.listen()
        cls.banner_port = banner.getsockname()[1]

        def serve_banner():
            while True:
                conn, _ = banner.accept()
                conn.sendall(b"SSH-2.0-test\r\n")
                conn.close()

        threading.Thread(target=serve_banner, daemon=True).start()

        cls.policy = f"{d}/egress.json"
        cls.write_policy("log", missing=False)
        cls.gate_root = f"{d}/gate"
        os.makedirs(cls.gate_root)
        cls.proxy_port = free_port()
        os.makedirs(f"{d}/conf")
        env = dict(
            os.environ,
            AGENT_EGRESS_POLICY=cls.policy,
            AGENT_EGRESS_PEERS=f"{cls.gate_root}/peers.json",
            AGENT_EGRESS_RUNTIME=f"{d}/allow.json",
            AGENT_EGRESS_ALLOW_INTERNAL="1",
        )
        cls.log = open(f"{d}/proxy.log", "w+")
        cls.proxy = subprocess.Popen(
            [
                MITMDUMP,
                "-q",
                "--listen-host",
                "127.0.0.1",
                "-p",
                str(cls.proxy_port),
                "--set",
                f"confdir={d}/conf",
                "--set",
                f"ssl_verify_upstream_trusted_ca={d}/up-ca.pem",
                "--set",
                "connection_strategy=eager",
                "-s",
                f"{HERE}/addon.py",
            ],
            env=env,
            stdout=cls.log,
            stderr=subprocess.STDOUT,
        )
        cls.gate_log = open(f"{d}/gate.log", "w")
        cls.gate = subprocess.Popen(
            [
                sys.executable,
                "-I",
                f"{HERE}/gate.py",
                "--root",
                cls.gate_root,
                "--proxy",
                f"127.0.0.1:{cls.proxy_port}",
                "--ca",
                f"{d}/conf/mitmproxy-ca-cert.pem",
                "--trust",
                f"{d}/up-ca.pem",
                "--client",
                pwd.getpwuid(os.getuid()).pw_name,
            ],
            stdout=cls.gate_log,
            stderr=subprocess.STDOUT,
        )
        for _ in range(200):
            if os.path.exists(f"{d}/conf/mitmproxy-ca-cert.pem") and os.path.exists(f"{cls.gate_root}/control.sock"):
                try:
                    socket.create_connection(("127.0.0.1", cls.proxy_port), timeout=0.2).close()
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            cls.log.flush()
            cls.gate_log.flush()
            with open(cls.log.name) as proxy_log, open(cls.gate_log.name) as gate_log:
                raise RuntimeError(
                    f"proxy or gate didn't start:\n{proxy_log.read()[-2000:]}\n{gate_log.read()[-2000:]}"
                )
        reply = cls.control({"op": "register", "name": "sbx-a", "pid": os.getpid()})
        assert reply["ok"], reply
        cls.sandbox_dir = reply["dir"]
        cls.trust = f"{cls.sandbox_dir}/ca-bundle.crt"
        cls.local_port = free_port()
        cls.bridge = subprocess.Popen(
            [
                "socat",
                f"TCP-LISTEN:{cls.local_port},bind=127.0.0.1,fork,reuseaddr",
                f"UNIX-CONNECT:{cls.sandbox_dir}/proxy.sock",
            ]
        )
        time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        for p in (cls.bridge, cls.gate, cls.proxy):
            p.terminate()
            p.wait(timeout=10)
        cls.upstream.shutdown()
        cls.log.close()
        cls.gate_log.close()
        cls.tmp.cleanup()

    @classmethod
    def write_policy(cls, mode, missing):
        token = f"{cls.d}/absent" if missing else f"{cls.d}/token"
        policy = {
            "mode": mode,
            "allow": [f"127.0.0.1:{cls.up_port}", f"127.0.0.1:{cls.banner_port}"],
            "inspect": [f"localhost:{cls.up_port}"],
            "inject": [
                {
                    "name": "fake",
                    "hosts": [f"127.0.0.2:{cls.up_port}"],
                    "header": "Authorization",
                    "format": "Bearer {}",
                    "file": token,
                }
            ],
        }
        tmp = cls.policy + ".tmp"
        with open(tmp, "w") as f:
            json.dump(policy, f)
        os.replace(tmp, cls.policy)

    @classmethod
    def control(cls, request):
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(f"{cls.gate_root}/control.sock")
            s.sendall((json.dumps(request) + "\n").encode())
            return json.loads(s.makefile().readline())

    def curl(self, url, *extra, proxy=None):
        proxy = proxy or f"http://127.0.0.1:{self.local_port}"
        result = subprocess.run(
            [
                "curl",
                "-s",
                "-m",
                "10",
                "-x",
                proxy,
                "--cacert",
                self.trust,
                "-w",
                "\n%{http_code} %{http_connect}",
                *extra,
                url,
            ],
            capture_output=True,
            text=True,
        )
        body, _, codes = result.stdout.rpartition("\n")
        return body, codes

    def records(self):
        self.log.flush()
        with open(self.log.name) as f:
            return [json.loads(line) for line in f if line.startswith("{")]

    def test_1_allowed_and_logged_with_identity(self):
        body, codes = self.curl(f"https://127.0.0.1:{self.up_port}/a")
        self.assertTrue(codes.startswith("200"), codes)
        self.assertFalse(json.loads(body)["injected"])
        rec = [r for r in self.records() if r.get("method") == "CONNECT" and r["port"] == self.up_port]
        self.assertEqual(rec[-1]["sandbox"], "sbx-a")
        self.assertEqual(rec[-1]["decision"], "allow")

    def test_2_log_mode_flags_unlisted(self):
        port = free_port()
        self.curl(f"https://127.0.0.1:{port}/x")
        rec = [r for r in self.records() if r.get("port") == port and r.get("method") == "CONNECT"]
        self.assertEqual(rec[-1]["decision"], "would-deny")

    def test_3_injects_for_bound_host_only(self):
        body, codes = self.curl(f"https://127.0.0.2:{self.up_port}/api", "-H", "Authorization: Bearer placeholder")
        self.assertTrue(codes.startswith("200"), codes)
        self.assertTrue(json.loads(body)["injected"])
        body, _ = self.curl(f"https://127.0.0.1:{self.up_port}/api", "-H", "Authorization: Bearer placeholder")
        self.assertFalse(json.loads(body)["has_secret"])
        rec = [r for r in self.records() if r.get("path") == "/api"]
        self.assertEqual(rec[-1]["injected"], "fake")
        self.assertEqual(rec[-1]["sandbox"], "sbx-a")

    def test_4_cleartext_to_bound_host_refused(self):
        _, codes = self.curl(f"http://127.0.0.2:{self.up_port}/api")
        self.assertTrue(codes.startswith("403"), codes)

    def test_5_unregistered_client_denied(self):
        _, codes = self.curl(f"https://127.0.0.1:{self.up_port}/a", proxy=f"http://127.0.0.1:{self.proxy_port}")
        self.assertIn("403", codes)
        rec = [r for r in self.records() if r.get("method") == "CONNECT"]
        self.assertEqual(rec[-1]["decision"], "deny-identity")

    def test_6_server_first_tcp(self):
        with socket.create_connection(("127.0.0.1", self.local_port), timeout=5) as s:
            s.sendall(f"CONNECT 127.0.0.1:{self.banner_port} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
            reply = b""
            while b"SSH-2.0" not in reply:
                chunk = s.recv(200)
                if not chunk:
                    break
                reply += chunk
        self.assertIn(b"SSH-2.0-test", reply)

    def test_7_missing_secret_fails_closed(self):
        self.write_policy("log", missing=True)
        try:
            body, codes = self.curl(f"https://127.0.0.2:{self.up_port}/api")
            self.assertTrue(codes.startswith("503"), codes)
            self.assertIn("credential_unavailable", body)
        finally:
            self.write_policy("log", missing=False)

    def test_8_enforce_after_reload(self):
        self.write_policy("enforce", missing=False)
        try:
            _, codes = self.curl(f"https://127.0.0.1:{free_port()}/x")
            self.assertIn("403", codes)
            body, codes = self.curl(f"https://127.0.0.1:{self.up_port}/a")
            self.assertTrue(codes.startswith("200"), codes)
        finally:
            self.write_policy("log", missing=False)

    def test_9_secret_never_logged(self):
        self.log.flush()
        with open(self.log.name) as f:
            self.assertNotIn(self.secret, f.read())
        with open(f"{self.d}/gate.log") as f:
            self.assertNotIn(self.secret, f.read())

    def raw(self, data):
        with socket.create_connection(("127.0.0.1", self.local_port), timeout=10) as s:
            s.sendall(data)
            reply = b""
            while b"\r\n\r\n" not in reply:
                chunk = s.recv(4096)
                if not chunk:
                    break
                reply += chunk
        return reply

    def tunnel(self, host, sni):
        s = socket.create_connection(("127.0.0.1", self.local_port), timeout=10)
        s.sendall(f"CONNECT {host}:{self.up_port} HTTP/1.1\r\nHost: {host}:{self.up_port}\r\n\r\n".encode())
        reply = b""
        while b"\r\n\r\n" not in reply:
            reply += s.recv(4096)
        self.assertIn(b" 200 ", reply.split(b"\r\n")[0])
        ctx = ssl.create_default_context(cafile=self.trust)
        ctx.check_hostname = False
        return ctx.wrap_socket(s, server_hostname=sni)

    def test_10_absolute_form_https_is_refused(self):
        reply = self.raw(
            f"GET https://127.0.0.1:{self.up_port}/steal HTTP/1.1\r\nHost: 127.0.0.2:{self.up_port}\r\n\r\n".encode()
        )
        self.assertIn(b" 403 ", reply.split(b"\r\n")[0])
        rec = [r for r in self.records() if r.get("path") == "/steal"]
        self.assertEqual(rec[-1]["decision"], "deny-absolute-https")
        self.assertEqual(rec[-1]["host"], "127.0.0.1")

    def test_11_host_header_must_match_the_target(self):
        port = free_port()
        reply = self.raw(
            f"GET http://127.0.0.3:{port}/exfil HTTP/1.1\r\nHost: 127.0.0.1:{self.up_port}\r\n\r\n".encode()
        )
        self.assertIn(b" 421 ", reply.split(b"\r\n")[0])
        rec = [r for r in self.records() if r.get("path") == "/exfil"]
        self.assertEqual(
            (rec[-1]["host"], rec[-1]["port"], rec[-1]["decision"]), ("127.0.0.3", port, "deny-misdirected")
        )
        body, codes = self.curl(f"https://localhost:{self.up_port}/cross", "-H", f"Host: 127.0.0.2:{self.up_port}")
        self.assertTrue(codes.startswith("421"), codes)
        self.assertNotIn("injected", body)
        rec = [r for r in self.records() if r.get("path") == "/cross"]
        self.assertEqual((rec[-1]["host"], rec[-1]["injected"]), ("localhost", None))

    def test_12_inspected_hostname_is_pinned_and_verified(self):
        body, codes = self.curl(f"https://localhost:{self.up_port}/pinned")
        self.assertTrue(codes.startswith("200"), codes)
        self.assertFalse(json.loads(body)["injected"])
        rec = [r for r in self.records() if r.get("path") == "/pinned"]
        self.assertEqual((rec[-1]["host"], rec[-1]["status"]), ("localhost", 200))

    def test_13_sni_must_match_the_connect_target(self):
        for host, sni in (("127.0.0.2", "localhost"), ("localhost", "uninspected.example")):
            with self.assertRaises((ssl.SSLError, OSError)):
                with self.tunnel(host, sni) as s:
                    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
                    if not s.recv(100):
                        raise OSError("closed")
        rec = [r for r in self.records() if r.get("decision") == "deny-sni"]
        self.assertEqual(
            {(r["host"], r["sni"]) for r in rec[-2:]},
            {("127.0.0.2", "localhost"), ("localhost", "uninspected.example")},
        )
        with self.tunnel("localhost", "localhost") as s:
            s.sendall(b"GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n")
            self.assertIn(b"200", s.recv(100))

    def test_zz_unregister_removes_the_socket(self):
        reply = self.control({"op": "register", "name": "sbx-b", "pid": os.getpid()})
        self.assertTrue(os.path.exists(f"{reply['dir']}/proxy.sock"))
        with open(f"{self.gate_root}/peers.json") as f:
            self.assertIn("sbx-b", json.load(f))
        held = socket.socket(socket.AF_UNIX)
        held.settimeout(5)
        held.connect(f"{reply['dir']}/proxy.sock")
        held.sendall(f"CONNECT 127.0.0.1:{self.up_port} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
        self.assertIn(b" 200 ", held.recv(200))
        self.assertTrue(self.control({"op": "unregister", "name": "sbx-b"})["ok"])
        self.assertEqual(held.recv(200), b"", "an unregistered sandbox's open tunnels are closed")
        held.close()
        self.assertFalse(os.path.exists(reply["dir"]))
        again = self.control({"op": "register", "name": "sbx-c", "pid": os.getpid()})
        self.assertNotEqual(again["address"], reply["address"], "a dropped address isn't handed out at once")
        self.control({"op": "unregister", "name": "sbx-c"})
        self.assertFalse(self.control({"op": "register", "name": "sbx-d", "pid": True})["ok"])
        self.assertFalse(self.control({"op": "register", "name": "../x", "pid": os.getpid()})["ok"])
        for networks in (["8.8.8.0/24"], ["10.0.0.0/4"], "172.19.0.0/16", ["x"]):
            request = {"op": "register", "name": "sbx-e", "pid": os.getpid(), "networks": networks}
            self.assertFalse(self.control(request)["ok"], networks)

    def test_zz_a_runner_replaces_its_sandboxs_stack_networks(self):
        def peers():
            with open(f"{self.gate_root}/peers.json") as f:
                return json.load(f)

        request = {"op": "register", "name": "sbx-s", "pid": os.getpid(), "networks": ["172.19.0.0/16"]}
        self.assertTrue(self.control(request)["ok"])
        stacks = {"op": "networks", "name": "sbx-s", "networks": ["172.20.0.0/16", "172.21.0.0/16"]}
        self.assertTrue(self.control(stacks)["ok"])
        self.assertEqual(peers()["sbx-s"]["networks"], ["172.19.0.0/16", "172.20.0.0/16", "172.21.0.0/16"])
        self.assertTrue(self.control({"op": "networks", "name": "sbx-s", "networks": []})["ok"])
        self.assertEqual(peers()["sbx-s"]["networks"], ["172.19.0.0/16"])
        self.assertFalse(self.control({**stacks, "networks": ["8.8.8.0/24"]})["ok"])
        self.assertEqual(self.control({**stacks, "name": "sbx-unknown"}), {"ok": True, "registered": False})
        sibling = {"op": "register", "name": "sbx-s-child", "pid": os.getpid(), "owner": "sbx-s"}
        self.assertTrue(self.control(sibling)["ok"])
        self.assertEqual(peers()["sbx-s-child"]["owner"], "sbx-s")
        self.control({"op": "unregister", "name": "sbx-s-child"})
        self.assertFalse(self.control({**sibling, "owner": "sbx-unknown"})["ok"])
        self.assertTrue(self.control(sibling)["ok"])
        self.assertTrue(self.control({"op": "unregister", "name": "sbx-s"})["ok"])
        self.assertIsNone(peers()["sbx-s-child"]["owner"], "a removed owner's siblings are detached")
        self.assertTrue(self.control(request)["ok"])
        self.assertIsNone(peers()["sbx-s-child"]["owner"], "a new sandbox under the old name isn't their owner")
        self.assertTrue(self.control({**sibling, "name": "sbx-s-child2"})["ok"])
        self.assertTrue(self.control(request)["ok"])
        self.assertIsNone(peers()["sbx-s-child2"]["owner"], "re-registering an owner detaches its siblings")
        self.control({"op": "unregister", "name": "sbx-s-child"})
        self.control({"op": "unregister", "name": "sbx-s-child2"})
        self.assertFalse(self.control({**sibling, "owner": "sbx-s-child"})["ok"])
        self.control({"op": "unregister", "name": "sbx-s"})
        self.assertNotIn("sbx-s", peers())


def load_addon():
    import importlib.util

    spec = importlib.util.spec_from_file_location("addon", f"{HERE}/addon.py")
    addon = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(addon)
    return addon


class Internal(unittest.TestCase):
    def connect(self, broker, host, port=443, sandbox="s"):
        from types import SimpleNamespace

        data = SimpleNamespace(
            server=SimpleNamespace(address=(host, port), sni=None, error=None),
            client=SimpleNamespace(agent_sandbox=sandbox),
        )
        import asyncio

        asyncio.run(broker.server_connect(data))
        return data.server

    def broker(self, answers, local=(), allow_private=(), networks=()):
        addon = load_addon()
        broker = addon.addons[0]
        broker.allow_internal = False
        broker.emit = lambda record: None
        broker.local = lambda: set(local)

        async def resolve(host, port):
            return list(answers.pop(0))

        broker.resolve = resolve
        broker.policy.peers = {
            "s": {"preview": {"address": "192.168.1.10", "ports": [18080]}, "networks": list(networks)},
            "sib": {"preview": {"address": "192.168.1.10", "ports": [18090]}, "owner": "s"},
            "orphan": {"preview": {"address": "192.168.1.10", "ports": [18091]}, "owner": "gone"},
            "other": {"preview": {}},
        }
        broker.policy.config = {**broker.policy.config, "allowPrivate": list(allow_private)}
        decisions = broker.decisions = []
        broker.emit = lambda record: decisions.append(record.get("decision"))
        return broker

    def test_host_and_metadata_addresses_are_internal(self):
        internal = load_addon().internal_address
        for ip in ("127.0.0.1", "127.77.0.2", "::1", "0.0.0.0", "169.254.169.254", "::ffff:127.0.0.1", "fe80::1%eth0"):
            self.assertTrue(internal(ip), ip)
        for ip in ("192.168.1.10", "10.0.0.1", "140.82.112.3", "2606:4700::1"):
            self.assertFalse(internal(ip), ip)

    def test_resolved_address_is_pinned(self):
        answers = [["2606:4700::1", "140.82.112.3"], ["127.0.0.1"]]
        broker = self.broker(answers)
        server = self.connect(broker, "rebind.example")
        self.assertIsNone(server.error)
        self.assertEqual((server.address, server.sni), (("140.82.112.3", 443), "rebind.example"))
        self.assertEqual(answers, [["127.0.0.1"]], "resolved once")

    def test_any_internal_answer_is_refused(self):
        server = self.connect(self.broker([["140.82.112.3", "127.0.0.1"]]), "rebind.example")
        self.assertIn("not reachable", server.error)

    def test_host_interface_addresses_are_refused_except_own_preview(self):
        local = {"192.168.1.10", "172.18.0.1"}
        for host, port, sandbox, refused in (
            ("192.168.1.10", 22, "s", True),
            ("172.18.0.1", 80, "s", True),
            ("192.168.1.10", 18080, "s", False),
            ("192.168.1.10", 18080, "other", True),
            ("192.168.1.10", 18090, "s", False),
            ("192.168.1.10", 18090, "sib", False),
            ("192.168.1.10", 18080, "sib", True),
            ("192.168.1.10", 18090, "other", True),
            ("192.168.1.10", 18091, "s", True),
            ("[::ffff:192.168.1.10]", 18090, "s", True),
            ("lan.example", 18081, "s", True),
            ("192.168.1.20", 80, "s", True),
            ("140.82.112.3", 80, "s", False),
        ):
            broker = self.broker([["192.168.1.10"]], local)
            server = self.connect(broker, host, port, sandbox)
            self.assertEqual(server.error is not None, refused, (host, port, sandbox))

    def test_ipv6_forms_of_host_addresses_are_refused(self):
        local = {"192.168.1.10", "172.17.0.23"}
        for host in (
            "::ffff:172.17.0.23",
            "[::ffff:172.17.0.23]",
            "::ffff:ac11:17",
            "::172.17.0.23",
            "64:ff9b::ac11:17",
            "2002:c0a8:010a::1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.169.254",
            "::ffff:192.168.1.10",
        ):
            server = self.connect(self.broker([], local), host, 18080)
            self.assertIsNotNone(server.error, host)
        for answer in (["::ffff:172.17.0.23"], ["140.82.112.3", "::ffff:192.168.1.10"], ["64:ff9b::7f00:1"]):
            server = self.connect(self.broker([answer], local), "mapped.example", 443)
            self.assertIsNotNone(server.error, answer)
        server = self.connect(self.broker([], local), "::ffff:140.82.112.3", 443)
        self.assertIsNone(server.error)

    def test_decimal_and_octal_names_resolve_before_the_check(self):
        addon = load_addon()
        broker = addon.addons[0]
        broker.allow_internal = False
        broker.emit = lambda record: None
        broker.local = lambda: set()
        for host in ("2130706433", "0177.0.0.1", "0x7f.1"):
            self.assertIsNotNone(self.connect(broker, host).error, host)

    def test_private_ranges_are_refused(self):
        for host in (
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.1.1",
            "100.64.0.1",
            "100.127.255.254",
            "fd00::1",
            "fc12::1",
            "fe80::1",
            "::ffff:10.1.2.3",
            "::ffff:c0a8:101",
            "::192.168.1.1",
            "64:ff9b::a01:203",
            "2002:c0a8:0101::1",
        ):
            broker = self.broker([])
            self.assertIsNotNone(self.connect(broker, host, 80).error, host)
        for host in ("172.32.0.1", "100.128.0.1", "11.0.0.1", "2606:4700::1"):
            self.assertIsNone(self.connect(self.broker([]), host, 80).error, host)

    def test_a_name_resolving_to_a_private_address_is_refused(self):
        broker = self.broker([["192.168.1.5"]])
        server = self.connect(broker, "router.example", 80)
        self.assertIn("allowPrivate", server.error)
        self.assertEqual(broker.decisions, ["deny-private"])
        broker = self.broker([["140.82.112.3", "::ffff:10.0.0.7"]])
        self.assertIsNotNone(self.connect(broker, "mixed.example", 443).error)

    def test_allow_private_entries(self):
        allow = ["192.168.1.5:2222", "10.0.0.0/8:443", "media.lan:8080", "[fd00::/8]:*"]
        for host, answers, port, allowed in (
            ("192.168.1.5", [], 2222, True),
            ("192.168.1.5", [], 22, False),
            ("::ffff:192.168.1.5", [], 2222, True),
            ("10.9.8.7", [], 443, True),
            ("10.9.8.7", [], 80, False),
            ("media.lan", [["192.168.1.9"]], 8080, True),
            ("media.lan", [["192.168.1.9"]], 22, False),
            ("other.lan", [["192.168.1.9"]], 8080, False),
            ("fd00::5", [], 9000, True),
            ("172.20.0.4", [], 80, False),
        ):
            server = self.connect(self.broker(answers, allow_private=allow), host, port)
            self.assertEqual(server.error is None, allowed, (host, port))

    def test_a_sandbox_reaches_its_own_docker_networks(self):
        nets = ["172.19.0.0/16"]
        self.assertIsNone(self.connect(self.broker([], networks=nets), "172.19.0.8", 8080).error)
        self.assertIsNotNone(self.connect(self.broker([], networks=nets), "172.20.0.8", 8080).error)
        self.assertIsNotNone(self.connect(self.broker([]), "172.19.0.8", 8080).error)
        self.assertIsNotNone(self.connect(self.broker([], local={"172.19.0.1"}, networks=nets), "172.19.0.1", 22).error)

    def test_local_addresses_reads_this_host(self):
        local = load_addon().local_addresses()
        self.assertIn("127.0.0.1", local)


class Report(unittest.TestCase):
    def test_suggests_unlisted_hosts_and_wildcards(self):
        sys.path.insert(0, HERE)
        import agent_egress

        lines = [
            json.dumps({"host": h, "port": p, "decision": d, "sandbox": "s", "ts": 1})
            for h, p, d in [
                ("a.cdn.example.com", 443, "would-deny"),
                ("b.cdn.example.com", 443, "would-deny"),
                ("c.cdn.example.com", 443, "would-deny"),
                ("pypi.org", 443, "would-deny"),
                ("media", 2222, "would-deny"),
                ("github.com", 443, "allow"),
                ('x"${builtins.abort "x"}', 443, "would-deny"),
                ("nas.lan", 8080, "would-deny"),
                ("nas.lan", 8080, "deny-private"),
            ]
        ] + ["not json"]
        targets = agent_egress.summarize(agent_egress.records(lines))
        self.assertEqual(targets[("github.com", 443)]["count"], 1)
        entries = agent_egress.suggest(targets, ["pypi.org"], 3)
        self.assertIn("*.example.com", entries)
        self.assertIn("media:2222", entries)
        self.assertNotIn("pypi.org", entries)
        self.assertNotIn("github.com", entries)
        self.assertNotIn("nas.lan:8080", entries, "a private refusal isn't the allowlist's to lift")
        self.assertFalse([e for e in entries if '"' in e or "$" in e], entries)


if __name__ == "__main__":
    unittest.main()
