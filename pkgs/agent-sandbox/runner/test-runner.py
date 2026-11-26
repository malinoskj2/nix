import io
import json
import os
import socket
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path

import importlib.util

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("runner.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

PROJECT = "asr-0123456789-stack"
LABELS = {runner.OWNER_LABEL: "agent-sandbox-test", runner.PROJECT_LABEL: PROJECT}


class Tree(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.realpath(self.tmp.name)
        self.worktree = f"{self.root}/projects/app"
        os.makedirs(f"{self.worktree}/.git")
        os.makedirs(f"{self.worktree}/data")
        os.makedirs(f"{self.root}/secret")
        Path(f"{self.root}/secret/key").write_text("secret")
        Path(f"{self.worktree}/token").write_text("token")
        os.symlink(f"{self.root}/secret", f"{self.worktree}/link")
        self.roots = [f"{self.root}/projects"]

    def tearDown(self):
        self.tmp.cleanup()

    def pins(self):
        pins = runner.Pins(self.worktree, self.roots)
        self.addCleanup(pins.close)
        return pins


class PinsTest(Tree):
    def test_subpaths_are_relative_to_the_root(self):
        pins = self.pins()
        self.assertEqual(pins.root, self.roots[0])
        self.assertEqual(pins.subpath(f"{self.worktree}/data", "dir"), "app/data")
        self.assertEqual(pins.subpath(self.worktree, "dir"), "app")
        self.assertEqual(pins.read(f"{self.worktree}/token"), b"token")
        with self.assertRaises(runner.Refused):
            pins.read(f"{self.worktree}/link/key")

    def test_refuses_symlinks_dotdot_and_outside(self):
        pins = self.pins()
        for path in (
            f"{self.worktree}/link",
            f"{self.worktree}/link/key",
            f"{self.worktree}/../../secret",
            f"{self.root}/secret",
            "relative",
            f"{self.worktree}//data",
        ):
            with self.subTest(path=path), self.assertRaises(runner.Refused):
                pins.subpath(path)

    def test_worktree_must_be_a_git_checkout_under_a_root(self):
        for path in (f"{self.root}/secret", f"{self.root}/projects", f"{self.worktree}/data"):
            with self.subTest(path=path), self.assertRaises(runner.Refused):
                runner.Pins(path, self.roots)
        os.rename(self.worktree, f"{self.root}/projects/real")
        os.symlink(f"{self.root}/projects/real", self.worktree)
        with self.assertRaises(runner.Refused):
            runner.Pins(self.worktree, self.roots)


def social_hub(worktree):
    return {
        "name": PROJECT,
        "services": {
            "postgres": {
                "image": "postgres:17-alpine",
                "restart": "unless-stopped",
                "environment": {"POSTGRES_PASSWORD": "x"},
                "volumes": [
                    {"type": "volume", "source": "postgres", "target": "/var/lib/postgresql/data", "volume": {}}
                ],
                "healthcheck": {"test": ["CMD-SHELL", "pg_isready"], "interval": "5s"},
                "networks": {"default": None},
            },
            "server": {
                "image": "social-hub:local",
                "build": {"context": worktree, "dockerfile": "Dockerfile", "args": {"REVISION": "dev"}},
                "command": ["serve"],
                "ports": [
                    {"mode": "ingress", "target": 8787, "published": "8787", "host_ip": "127.0.0.1", "protocol": "tcp"}
                ],
                "depends_on": {"postgres": {"condition": "service_healthy", "required": True}},
                "deploy": {"replicas": 1},
                "networks": {"default": None},
            },
            "worker": {
                "image": "social-hub:local",
                "build": {"context": worktree, "dockerfile": "Dockerfile"},
                "networks": {"default": None},
            },
            "wiremock": {
                "image": "wiremock/wiremock:3.13.0",
                "volumes": [
                    {
                        "type": "bind",
                        "source": f"{worktree}/data",
                        "target": "/home/wiremock",
                        "read_only": True,
                        "bind": {"create_host_path": True},
                    }
                ],
                "networks": {"default": None},
            },
        },
        "networks": {"default": {"name": f"{PROJECT}_default", "ipam": {}}},
        "volumes": {"postgres": {"name": f"{PROJECT}_postgres"}},
    }


class ComposeTest(Tree):
    def validate(self, model):
        return runner.ComposeModel(model, PROJECT, self.pins(), LABELS, "asr-root").validate()

    def test_accepts_and_confines_a_real_stack(self):
        model = self.validate(social_hub(self.worktree))
        server, worker = model["services"]["server"], model["services"]["worker"]
        self.assertEqual(server["image"], worker["image"])
        self.assertTrue(server["image"].startswith(f"{PROJECT}-built/"))
        self.assertEqual(
            server["ports"], [{"mode": "ingress", "target": 8787, "host_ip": "127.0.0.1", "protocol": "tcp"}]
        )
        for service in model["services"].values():
            self.assertEqual(service["cgroup_parent"], "agent-sandbox.slice")
            self.assertEqual(service["security_opt"], ["no-new-privileges:true"])
            self.assertEqual(service["restart"], "no")
            self.assertLessEqual(service["pids_limit"], runner.MAX_PIDS)
            self.assertEqual(service["labels"][runner.OWNER_LABEL], "agent-sandbox-test")
        mount = model["services"]["wiremock"]["volumes"][0]
        self.assertEqual(
            mount,
            {
                "type": "volume",
                "source": runner.ROOT_VOLUME,
                "target": "/home/wiremock",
                "read_only": True,
                "volume": {"subpath": "app/data"},
            },
        )
        self.assertEqual(model["volumes"][runner.ROOT_VOLUME], {"external": True, "name": "asr-root"})
        self.assertEqual(model["volumes"]["postgres"]["labels"][runner.PROJECT_LABEL], PROJECT)
        self.assertEqual(model["networks"]["default"]["labels"][runner.PROJECT_LABEL], PROJECT)
        self.assertEqual(model["services"]["server"]["build"]["labels"][runner.OWNER_LABEL], "agent-sandbox-test")

    def refused(self, change):
        model = social_hub(self.worktree)
        change(model)
        with self.assertRaises(runner.Refused):
            self.validate(model)

    def test_refusals(self):
        services = lambda m: m["services"]  # noqa: E731
        cases = {
            "privileged": lambda m: services(m)["postgres"].update(privileged=True),
            "cap_add": lambda m: services(m)["postgres"].update(cap_add=["SYS_ADMIN"]),
            "host network": lambda m: services(m)["postgres"].update(network_mode="host"),
            "other container's network": lambda m: services(m)["postgres"].update(network_mode="container:x"),
            "host pid": lambda m: services(m)["postgres"].update(pid="host"),
            "userns": lambda m: services(m)["postgres"].update(userns_mode="host"),
            "devices": lambda m: services(m)["postgres"].update(devices=["/dev/kmsg"]),
            "seccomp": lambda m: services(m)["postgres"].update(security_opt=["seccomp=unconfined"]),
            "cgroup_parent": lambda m: services(m)["postgres"].update(cgroup_parent="/"),
            "container_name": lambda m: services(m)["postgres"].update(container_name="agent-sandbox-x"),
            "bind outside": lambda m: services(m)["wiremock"]["volumes"][0].update(source=f"{self.root}/secret"),
            "bind through symlink": lambda m: services(m)["wiremock"]["volumes"][0].update(
                source=f"{self.worktree}/link"
            ),
            "bind propagation": lambda m: services(m)["wiremock"]["volumes"][0].update(bind={"propagation": "shared"}),
            "short bind": lambda m: services(m)["wiremock"].update(volumes=["/:/host"]),
            "external volume": lambda m: m["volumes"].update(other={"name": "other", "external": True}),
            "shared volume name": lambda m: m["volumes"]["postgres"].update(name="agent-sandbox-home"),
            "volume driver options": lambda m: m["volumes"]["postgres"].update(
                driver_opts={"type": "none", "o": "bind", "device": "/"}
            ),
            "undeclared volume": lambda m: services(m)["postgres"]["volumes"][0].update(source="elsewhere"),
            "external network": lambda m: m["networks"].update(host={"name": "host", "external": True}),
            "network driver": lambda m: m["networks"]["default"].update(driver="macvlan"),
            "sandbox image": lambda m: services(m)["postgres"].update(image="agent-sandbox:0123"),
            "build host network": lambda m: services(m)["server"]["build"].update(network="host"),
            "build ssh": lambda m: services(m)["server"]["build"].update(ssh=["default"]),
            "build tags": lambda m: services(m)["server"]["build"].update(tags=["agent-sandbox:x"]),
            "build context outside": lambda m: services(m)["server"]["build"].update(context=f"{self.root}/secret"),
            "dockerfile escape": lambda m: services(m)["server"]["build"].update(dockerfile="../../secret/key"),
            "secret from host env": lambda m: m.update(secrets={"s": {"environment": "HOME"}}),
            "secret outside": lambda m: m.update(secrets={"s": {"file": f"{self.root}/secret/key"}}),
            "gpu": lambda m: services(m)["postgres"].update(
                deploy={"resources": {"reservations": {"devices": [{"capabilities": ["gpu"]}]}}}
            ),
            "replicas": lambda m: services(m)["server"].update(deploy={"replicas": 100}),
            "logging driver": lambda m: services(m)["postgres"].update(logging={"driver": "syslog"}),
            "reserved label": lambda m: services(m)["postgres"].update(labels={runner.OWNER_LABEL: "someone-else"}),
            "project name": lambda m: m.update(name="other"),
            "volumes_from container": lambda m: services(m)["postgres"].update(
                volumes_from=["container:agent-sandbox-x"]
            ),
            "provider": lambda m: services(m)["postgres"].update(provider={"type": "x"}),
            "reserved volume": lambda m: services(m)["postgres"]["volumes"][0].update(source=runner.ROOT_VOLUME),
            "reserved volume key": lambda m: m["volumes"].update({"asr-worktree-root": {}}),
            "global mode": lambda m: services(m)["server"].update(deploy={"mode": "global"}),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.refused(change)

    def test_secret_file_inside_is_pinned(self):
        model = social_hub(self.worktree)
        model["secrets"] = {"token": {"file": f"{self.worktree}/token"}}
        model["services"]["postgres"]["secrets"] = [{"source": "token"}]
        directory = Path(self.root, "project")
        checker = runner.ComposeModel(model, PROJECT, self.pins(), LABELS, "asr-root", directory)
        secret = checker.validate()["secrets"]["token"]
        self.assertEqual(secret, {"file": f"{directory}/secrets/token"})
        self.assertEqual(Path(secret["file"]).read_text(), "token")

    def test_swarm_deploy_keys_are_dropped_with_a_warning(self):
        model = social_hub(self.worktree)
        model["services"]["worker"]["deploy"] = {
            "replicas": 1,
            "placement": {"constraints": ["node.role==manager"]},
            "restart_policy": {},
            "resources": {"limits": {"memory": "512m"}},
        }
        checker = runner.ComposeModel(model, PROJECT, self.pins(), LABELS, "asr-root")
        deploy = checker.validate()["services"]["worker"]["deploy"]
        self.assertEqual(deploy, {"replicas": 1, "resources": {"limits": {"memory": "512m"}}})
        self.assertEqual(len(checker.warnings), 1)


class RetagTest(unittest.TestCase):
    def archive(self, path, manifest, extra=()):
        with tarfile.open(path, "w") as archive:
            for name, data in [("manifest.json", json.dumps(manifest).encode()), ("repositories", b"{}"), *extra]:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

    def test_names_only_with_the_runner_tag(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp, "in.tar"), Path(tmp, "out.tar")
            self.archive(
                source,
                [{"Config": "c.json", "RepoTags": ["agent-sandbox:victim", "postgres:17"], "Layers": []}],
                [("c.json", b"{}")],
            )
            runner.Runner.retag(source, output, "agent-sandbox-candidate:x-1")
            with tarfile.open(output) as archive:
                self.assertEqual(sorted(archive.getnames()), ["c.json", "manifest.json"])
                manifest = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(manifest[0]["RepoTags"], ["agent-sandbox-candidate:x-1"])

    def test_refuses_several_images_and_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, output = Path(tmp, "in.tar"), Path(tmp, "out.tar")
            self.archive(source, [{"RepoTags": []}, {"RepoTags": []}])
            with self.assertRaises(runner.Refused):
                runner.Runner.retag(source, output, "t")
            with tarfile.open(source, "w") as archive:
                info = tarfile.TarInfo("evil")
                info.type = tarfile.SYMTYPE
                info.linkname = "/etc/passwd"
                archive.addfile(info)
            with self.assertRaises(runner.Refused):
                runner.Runner.retag(source, output, "t")


class ServerTest(Tree):
    def setUp(self):
        super().setUp()
        self.docker_log = Path(self.root, "docker.log")
        fake = Path(self.root, "docker")
        fake.write_text(f'#!/bin/sh\necho "$*" >> {self.docker_log}\n')
        fake.chmod(0o755)
        args = runner.parse_args(
            [
                "--owner",
                "agent-sandbox-test",
                "--socket",
                f"{self.root}/runner.sock",
                "--state-dir",
                f"{self.root}/state/x",
                "--image",
                "agent-sandbox:" + "0" * 32,
                "--root",
                self.roots[0],
                "--passwd",
                "/etc/passwd",
                "--group",
                "/etc/group",
                "--ports-lock",
                f"{self.root}/ports.lock",
                "--docker",
                str(fake),
            ]
        )
        self.server = runner.Server(args.socket, runner.Runner(args))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def call(self, request):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(f"{self.root}/runner.sock")
            connection.sendall((json.dumps(request) + "\n").encode())
            messages = [json.loads(line) for line in connection.makefile().read().splitlines()]
        return messages[-1]

    def test_refuses_what_is_not_an_operation(self):
        self.assertIn("unknown operation", self.call({"op": "docker.run", "args": ["--privileged"]})["error"])
        self.assertIn("error", self.call({"op": "sandbox.exec", "id": "agent-sandbox-someone-else", "argv": ["id"]}))
        self.assertIn("error", self.call({"op": "sandbox.rm", "id": "agent-sandbox-codex-server"}))
        self.assertIn("error", self.call({"op": "compose.down", "name": "stack"}))
        self.assertIn("error", self.call({"op": "compose.up", "name": "../x", "model": {}}))
        self.assertIn("error", self.call({"op": "sandbox.launch", "image": "ubuntu:24.04", "worktree": self.worktree}))
        self.assertIn("error", self.call({"op": "image.load", "path": "/etc/passwd"}))
        self.assertFalse(self.docker_log.exists() and "rm" in self.docker_log.read_text())

    def test_project_names_are_owner_scoped(self):
        project = self.call({"op": "compose.project", "name": "stack"})["result"]["project"]
        self.assertEqual(project, f"asr-{runner.short_hash('agent-sandbox-test')}-stack")


if __name__ == "__main__":
    unittest.main()
