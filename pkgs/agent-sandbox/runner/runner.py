#!/usr/bin/env python3
import argparse
import copy
import errno
import fcntl
import hashlib
import io
import json
import os
import re
import secrets
import selectors
import shutil
import signal
import socket
import socketserver
import stat
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path

OWNER_LABEL = "agent-sandbox.runner.owner"
KIND_LABEL = "agent-sandbox.runner.kind"
PROJECT_LABEL = "agent-sandbox.runner.project"
MAX_REQUEST = 4 << 20
MAX_CONNECTIONS = 16
MAX_SANDBOXES = 4
MAX_PROJECTS = 4
MAX_IMAGES = 4
MAX_REPLICAS = 8
MAX_PIDS = 4096
DEFAULT_TIMEOUT = 1800
MAX_TIMEOUT = 4 * 3600
MAX_IMAGE_BYTES = 4 << 30
MAX_OUTPUT_LINES = 10000
CHUNK = 65536
PREVIEW_PORTS = range(8080, 8085)
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
TRUSTED_IMAGE_RE = re.compile(r"^agent-sandbox:[a-z0-9]{32}$")
SANDBOX_IMAGE_RE = re.compile(r"^(docker\.io/)?(library/)?agent-sandbox(-candidate)?(:|@|$)")


class Refused(Exception):
    pass


def refuse(message):
    raise Refused(message)


def short_hash(text, length=10):
    return hashlib.sha256(text.encode()).hexdigest()[:length]


def path_parts(path):
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        refuse(f"not an absolute path: {path!r}")
    parts = path.split("/")[1:]
    if parts == [""]:
        return []
    if any(part in ("", ".", "..") for part in parts):
        refuse(f"path must be normalized, without . or .. or //: {path}")
    return parts


def open_beneath(dir_fd, parts, kind, shown):
    """Open parts under dir_fd one component at a time, following no symlink."""
    fd = os.dup(dir_fd)
    try:
        for index, part in enumerate(parts):
            flags = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
            if index < len(parts) - 1 or kind == "dir":
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        mode = os.fstat(fd).st_mode
        if kind == "dir" and not stat.S_ISDIR(mode):
            refuse(f"not a directory: {shown}")
        if kind == "file" and not stat.S_ISREG(mode):
            refuse(f"not a regular file: {shown}")
        if kind == "any" and not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            refuse(f"not a file or directory: {shown}")
        return fd
    except OSError as error:
        os.close(fd)
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            refuse(f"{shown}: a component is a symlink or not a directory")
        refuse(f"{shown}: {error.strerror}")
    except Refused:
        os.close(fd)
        raise


class Pins:
    """Host paths held open by descriptor, so a later symlink swap cannot redirect them.

    Docker resolves a bind source when it mounts it. A source of /proc/<pid>/fd/<n> makes it
    mount exactly the directory validated here, wherever the caller renames things afterwards.
    """

    def __init__(self, worktree, roots):
        self.fds = []
        self.worktree = worktree
        self.worktree_parts = path_parts(worktree)
        for root in roots:
            root_parts = path_parts(root)
            if self.worktree_parts[: len(root_parts)] == root_parts and len(self.worktree_parts) > len(root_parts):
                root_fd = os.open(root, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
                try:
                    self.fd = open_beneath(root_fd, self.worktree_parts[len(root_parts) :], "dir", worktree)
                finally:
                    os.close(root_fd)
                self.fds.append(self.fd)
                break
        else:
            refuse(f"worktree must be inside one of: {', '.join(roots)}")
        try:
            os.stat(".git", dir_fd=self.fd, follow_symlinks=False)
        except OSError:
            self.close()
            refuse(f"not a Git worktree (no .git): {worktree}")

    def inside(self, path):
        parts = path_parts(path)
        if parts[: len(self.worktree_parts)] != self.worktree_parts:
            refuse(f"path outside the worktree {self.worktree}: {path}")
        return parts[len(self.worktree_parts) :]

    def pin(self, path, kind="any"):
        fd = open_beneath(self.fd, self.inside(path), kind, path)
        self.fds.append(fd)
        return f"/proc/{os.getpid()}/fd/{fd}"

    @property
    def worktree_source(self):
        return f"/proc/{os.getpid()}/fd/{self.fd}"

    def close(self):
        for fd in self.fds:
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds = []


# Compose model validation. The client renders the file with `docker compose config` inside its
# sandbox, so every include, extends, env_file and interpolation is resolved with what the caller
# can already read. Here the rendered model is treated as untrusted data: unknown keys are
# refused rather than passed through.

SERVICE_KEYS = {
    "build",
    "command",
    "configs",
    "cap_drop",
    "cpu_shares",
    "cpus",
    "depends_on",
    "deploy",
    "dns",
    "dns_search",
    "domainname",
    "entrypoint",
    "environment",
    "expose",
    "extra_hosts",
    "healthcheck",
    "hostname",
    "image",
    "init",
    "labels",
    "links",
    "logging",
    "mem_limit",
    "mem_reservation",
    "memswap_limit",
    "network_mode",
    "networks",
    "oom_score_adj",
    "pids_limit",
    "platform",
    "ports",
    "post_start",
    "pre_stop",
    "privileged",
    "profiles",
    "pull_policy",
    "read_only",
    "restart",
    "scale",
    "secrets",
    "security_opt",
    "shm_size",
    "stdin_open",
    "stop_grace_period",
    "stop_signal",
    "tmpfs",
    "tty",
    "ulimits",
    "user",
    "volumes",
    "volumes_from",
    "working_dir",
}
BUILD_KEYS = {
    "context",
    "dockerfile",
    "dockerfile_inline",
    "args",
    "target",
    "labels",
    "network",
    "extra_hosts",
    "shm_size",
    "platforms",
    "pull",
    "no_cache",
    "secrets",
}
DEPLOY_KEYS = {"replicas", "resources"}
RESOURCE_KEYS = {"cpus", "memory", "pids"}
NETWORK_KEYS = {"name", "driver", "internal", "labels", "ipam", "enable_ipv6"}
VOLUME_KEYS = {"name", "driver", "labels"}
SECRET_KEYS = {"name", "file", "content"}
ULIMIT_KEYS = {"nofile", "nproc", "memlock", "stack", "core"}
LOGGING_DRIVERS = {"json-file", "local"}


def is_extension(key):
    return isinstance(key, str) and key.startswith("x-")


def check_keys(where, mapping, allowed):
    if not isinstance(mapping, dict):
        refuse(f"{where}: expected a mapping")
    for key in mapping:
        if key not in allowed and not is_extension(key):
            refuse(f"{where}: {key} is not allowed")


def add_labels(entry, labels):
    existing = entry.get("labels") or {}
    if isinstance(existing, list):
        existing = dict(item.split("=", 1) if "=" in item else (item, "") for item in existing)
    if not isinstance(existing, dict):
        refuse("labels must be a mapping or list")
    for key in existing:
        if str(key).startswith("agent-sandbox."):
            refuse(f"label {key} is reserved")
    entry["labels"] = {**existing, **labels}


class ComposeModel:
    def __init__(self, model, project, pins, labels):
        self.model = copy.deepcopy(model)
        self.project = project
        self.pins = pins
        self.labels = labels
        self.images = {}

    def validate(self):
        model = self.model
        check_keys("compose", model, {"name", "services", "networks", "volumes", "secrets", "configs"})
        if model.get("name", self.project) != self.project:
            refuse(f"the rendered project name must be {self.project}")
        model["name"] = self.project
        services = model.get("services")
        if not isinstance(services, dict) or not services:
            refuse("compose: no services")
        networks = model.setdefault("networks", {}) or {}
        model["networks"] = networks
        for key, network in networks.items():
            self.network(key, network)
        volumes = model.get("volumes") or {}
        for key, volume in volumes.items():
            self.volume(key, volume)
        for kind in ("secrets", "configs"):
            for key, entry in (model.get(kind) or {}).items():
                self.secret(kind, key, entry)
        for name, service in services.items():
            if isinstance(service, dict) and isinstance(service.get("build"), dict):
                image = service.get("image") or f"{self.project}-{name}"
                self.images.setdefault(image, f"{self.project}-built/{self.image_suffix(image)}")
        for name, service in services.items():
            self.service(name, service, services, networks, volumes)
        return self.model

    @staticmethod
    def image_suffix(image):
        suffix = re.sub(r"[^a-z0-9._-]+", "-", image.lower()).strip("-.")
        return f"{suffix or 'image'}:latest"

    def network(self, key, network):
        network = network or {}
        self.model["networks"][key] = network
        check_keys(f"networks.{key}", network, NETWORK_KEYS)
        if network.get("name", f"{self.project}_{key}") != f"{self.project}_{key}":
            refuse(f"networks.{key}: name must be {self.project}_{key}; external and shared networks are refused")
        if network.get("driver", "bridge") != "bridge":
            refuse(f"networks.{key}: only the bridge driver is allowed")
        if network.get("ipam") not in (None, {}):
            refuse(f"networks.{key}: custom IPAM is refused")
        network.pop("ipam", None)
        add_labels(network, self.labels)

    def volume(self, key, volume):
        volume = volume or {}
        self.model["volumes"][key] = volume
        check_keys(f"volumes.{key}", volume, VOLUME_KEYS)
        if volume.get("name", f"{self.project}_{key}") != f"{self.project}_{key}":
            refuse(f"volumes.{key}: name must be {self.project}_{key}; external and shared volumes are refused")
        if volume.get("driver", "local") != "local":
            refuse(f"volumes.{key}: only the local driver without options is allowed")
        add_labels(volume, self.labels)

    def secret(self, kind, key, entry):
        check_keys(f"{kind}.{key}", entry, SECRET_KEYS)
        if "name" in entry and entry["name"] != f"{self.project}_{key}":
            refuse(f"{kind}.{key}: a custom name is refused")
        if "file" in entry:
            entry["file"] = self.pins.pin(entry["file"], "file")
        elif "content" not in entry:
            refuse(f"{kind}.{key}: only file and content sources are allowed")

    def service(self, name, service, services, networks, volumes):
        where = f"services.{name}"
        check_keys(where, service, SERVICE_KEYS)
        if service.get("privileged"):
            refuse(f"{where}: privileged is refused")
        service.pop("privileged", None)
        service.pop("profiles", None)
        image = service.get("image")
        if "build" in service:
            self.build(where, service["build"])
            image = image or f"{self.project}-{name}"
        if image is not None:
            if not isinstance(image, str) or not image:
                refuse(f"{where}: image must be a string")
            if image in self.images:
                service["image"] = self.images[image]
            elif SANDBOX_IMAGE_RE.match(image):
                refuse(f"{where}: sandbox images run through `sandbox-runner sandbox launch`")
        mode = service.get("network_mode")
        if mode is not None:
            target = mode.removeprefix("service:")
            if mode != "none" and not (mode.startswith("service:") and target in services):
                refuse(f"{where}: network_mode must be none or service:<service in this project>")
        for source in service.get("volumes_from") or []:
            if not isinstance(source, str) or source.split(":", 1)[0] not in services:
                refuse(f"{where}: volumes_from must name a service in this project")
        for link in service.get("links") or []:
            if not isinstance(link, str) or link.split(":", 1)[0] not in services:
                refuse(f"{where}: links must name a service in this project")
        service_networks = service.get("networks") or {}
        for key in service_networks:
            if key not in networks:
                refuse(f"{where}: network {key} is not defined in this project")
        if mode is None and not service_networks:
            networks.setdefault("default", {"name": f"{self.project}_default", "labels": dict(self.labels)})
        security = service.get("security_opt") or []
        for option in security:
            if option not in ("no-new-privileges", "no-new-privileges:true", "no-new-privileges=true"):
                refuse(f"{where}: security_opt {option} is refused")
        service["security_opt"] = ["no-new-privileges:true"]
        logging = service.get("logging")
        if logging is not None:
            check_keys(f"{where}.logging", logging, {"driver", "options"})
            if logging.get("driver", "json-file") not in LOGGING_DRIVERS:
                refuse(f"{where}: logging driver must be json-file or local")
        for limit in service.get("ulimits") or {}:
            if limit not in ULIMIT_KEYS:
                refuse(f"{where}: ulimit {limit} is refused")
        deploy = service.get("deploy")
        if deploy is not None:
            check_keys(f"{where}.deploy", deploy, DEPLOY_KEYS)
            resources = deploy.get("resources") or {}
            check_keys(f"{where}.deploy.resources", resources, {"limits", "reservations"})
            for kind, entry in resources.items():
                check_keys(f"{where}.deploy.resources.{kind}", entry, RESOURCE_KEYS)
            if int(deploy.get("replicas", 1)) > MAX_REPLICAS:
                refuse(f"{where}: at most {MAX_REPLICAS} replicas")
        if int(service.get("scale", 1)) > MAX_REPLICAS:
            refuse(f"{where}: at most {MAX_REPLICAS} replicas")
        for kind in ("secrets", "configs"):
            for reference in service.get(kind) or []:
                source = reference.get("source") if isinstance(reference, dict) else reference
                if source not in (self.model.get(kind) or {}):
                    refuse(f"{where}: {kind} {source} is not defined in this project")
        service["ports"] = [self.port(where, port) for port in service.get("ports") or []]
        if not service["ports"]:
            del service["ports"]
        service["volumes"] = [self.mount(where, mount, volumes) for mount in service.get("volumes") or []]
        if not service["volumes"]:
            del service["volumes"]
        pids = service.get("pids_limit")
        service["pids_limit"] = MAX_PIDS if pids in (None, -1, 0) else min(int(pids), MAX_PIDS)
        service["oom_score_adj"] = max(500, int(service.get("oom_score_adj", 500)))
        service["restart"] = "no"
        service["cgroup_parent"] = "agent-sandbox.slice"
        add_labels(service, self.labels)

    def build(self, where, build):
        check_keys(f"{where}.build", build, BUILD_KEYS)
        context = build.get("context")
        if not isinstance(context, str):
            refuse(f"{where}.build: context must be a local directory in the worktree")
        self.pins.inside(context)
        dockerfile = build.get("dockerfile")
        if dockerfile is not None:
            path = dockerfile if dockerfile.startswith("/") else f"{context}/{dockerfile}"
            self.pins.inside(os.path.normpath(path))
            if os.path.normpath(path) != path and not dockerfile.startswith("/"):
                refuse(f"{where}.build: dockerfile must be a normalized path inside the worktree")
        if build.get("network") not in (None, "default", "none"):
            refuse(f"{where}.build: network must be default or none")
        for reference in build.get("secrets") or []:
            source = reference.get("source") if isinstance(reference, dict) else reference
            if source not in (self.model.get("secrets") or {}):
                refuse(f"{where}.build: secret {source} is not defined in this project")
        add_labels(build, self.labels)

    @staticmethod
    def port(where, port):
        if isinstance(port, (str, int)):
            refuse(f"{where}: ports must be rendered in long form; render with docker compose config")
        check_keys(
            f"{where}.ports", port, {"target", "published", "host_ip", "protocol", "mode", "name", "app_protocol"}
        )
        if port.get("host_ip") not in (None, "", "127.0.0.1", "0.0.0.0", "::"):
            refuse(f"{where}: ports may only bind loopback")
        port = {key: value for key, value in port.items() if key != "published"}
        port["host_ip"] = "127.0.0.1"
        return port

    def mount(self, where, mount, volumes):
        if not isinstance(mount, dict):
            refuse(f"{where}: volumes must be rendered in long form; render with docker compose config")
        kind = mount.get("type")
        check_keys(
            f"{where}.volumes",
            mount,
            {"type", "source", "target", "read_only", "bind", "volume", "tmpfs", "consistency"},
        )
        if kind == "bind":
            check_keys(f"{where}.volumes.bind", mount.get("bind") or {}, {"create_host_path", "selinux"})
            mount = {**mount, "source": self.pins.pin(mount.get("source"), "any")}
            mount.pop("bind", None)
        elif kind == "volume":
            source = mount.get("source")
            if source and source not in volumes:
                refuse(f"{where}: volume {source} is not defined in this project")
            check_keys(f"{where}.volumes.volume", mount.get("volume") or {}, {"nocopy", "subpath"})
        elif kind != "tmpfs":
            refuse(f"{where}: mount type {kind} is refused")
        return mount


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Runner:
    def __init__(self, args):
        self.args = args
        self.owner = args.owner
        self.oid = short_hash(args.owner)
        self.state = Path(args.state_dir)
        self.lock = threading.Lock()
        self.sandboxes = {}
        self.projects = {}
        self.images = []
        self.project_locks = {}
        self.base_labels = {OWNER_LABEL: self.owner}

    # Docker helpers

    def docker(self, *argv, check=True, timeout=300, input=None):
        result = subprocess.run(
            [self.args.docker, *argv],
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input,
        )
        if check and result.returncode != 0:
            raise Refused(f"docker {argv[0]} failed: {result.stderr.strip()[-2000:]}")
        return result

    def owned(self, kind, *filters):
        args = [kind, "ls" if kind != "ps" else "-a", "-q", "--filter", f"label={OWNER_LABEL}={self.owner}"]
        if kind == "ps":
            args = ["ps", "-a", "-q", "--filter", f"label={OWNER_LABEL}={self.owner}"]
        for item in filters:
            args += ["--filter", item]
        return self.docker(*args, check=False).stdout.split()

    def remove_owned(self, *filters):
        containers = self.owned("ps", *filters)
        if containers:
            self.docker("rm", "--force", "--volumes", *containers, check=False)
        for network in self.owned("network", *filters):
            self.disconnect_owner(network)
            self.docker("network", "rm", network, check=False)
        volumes = self.owned("volume", *filters)
        if volumes:
            self.docker("volume", "rm", "--force", *volumes, check=False)
        images = self.docker(
            "image",
            "ls",
            "-q",
            "--filter",
            f"label={OWNER_LABEL}={self.owner}",
            *sum((["--filter", f] for f in filters), []),
            check=False,
        ).stdout.split()
        if images:
            self.docker("image", "rm", "--force", *sorted(set(images)), check=False)

    def disconnect_owner(self, network):
        self.docker("network", "disconnect", "--force", network, self.owner, check=False)

    def sweep_orphans(self):
        """Remove what a runner killed before its cleanup left behind, and anything this owner left."""
        owners = set()
        for kind in ("ps", "network", "volume"):
            listing = ["ps", "-a"] if kind == "ps" else [kind, "ls"]
            output = self.docker(
                *listing, "--filter", f"label={OWNER_LABEL}", "--format", f'{{{{.Label "{OWNER_LABEL}"}}}}', check=False
            ).stdout
            owners.update(line for line in output.split() if line)
        live_runners = {}
        for directory in self.state.parent.glob("*/"):
            try:
                owner = (directory / "owner").read_text().strip()
                pid = int((directory / "pid").read_text())
            except (OSError, ValueError):
                continue
            if directory != self.state and pid_alive(pid):
                live_runners[owner] = directory
        for owner in owners:
            if owner != self.owner and (owner in live_runners or self.container_exists(owner)):
                continue
            sweeper = Runner.__new__(Runner)
            sweeper.args, sweeper.owner = self.args, owner
            sweeper.remove_owned()
        for directory in self.state.parent.glob("*/"):
            try:
                owner = (directory / "owner").read_text().strip()
            except OSError:
                owner = None
            if directory == self.state or (owner not in live_runners and not (owner and self.container_exists(owner))):
                if owner:
                    self.remove_candidate_images(short_hash(owner))
                subprocess.run(["chmod", "-R", "u+w", str(directory)], capture_output=True)
                shutil.rmtree(directory, ignore_errors=True)

    def container_exists(self, name):
        return self.docker("container", "inspect", name, check=False).returncode == 0

    def reap(self):
        """Disposable things are for one review: remove those idle past the TTL."""
        while True:
            time.sleep(60)
            now = time.monotonic()
            with self.lock:
                idle_sandboxes = [n for n, e in self.sandboxes.items() if now - e["touched"] > self.args.ttl]
                idle_projects = [n for n, e in self.projects.items() if now - e["touched"] > self.args.ttl]
            for name in idle_sandboxes:
                self.sandbox_rm({"id": name}, lambda *_: None)
            for project in idle_projects:
                with self.compose_lock(project):
                    self.compose_down_locked(project, quiet=True)

    def remove_candidate_images(self, oid):
        output = self.docker(
            "image", "ls", "--format", "{{.Repository}}:{{.Tag}}", "agent-sandbox-candidate", check=False
        ).stdout
        tags = [tag for tag in output.split() if tag.startswith(f"agent-sandbox-candidate:{oid}-")]
        if tags:
            self.docker("image", "rm", "--force", *tags, check=False)

    def cleanup(self):
        for project in list(self.projects):
            self.compose_down_locked(project, quiet=True)
        self.remove_owned()
        for sandbox in self.sandboxes.values():
            sandbox["pins"].close()
        self.remove_candidate_images(self.oid)
        subprocess.run(["chmod", "-R", "u+w", str(self.state)], capture_output=True)
        shutil.rmtree(self.state, ignore_errors=True)

    # Images

    def image_load(self, request, emit):
        with self.lock:
            if len(self.images) >= MAX_IMAGES:
                refuse(f"at most {MAX_IMAGES} candidate images per sandbox; remove a sandbox first")
            tag = f"agent-sandbox-candidate:{self.oid}-{len(self.images) + 1}-{secrets.token_hex(3)}"
            self.images.append(tag)
        try:
            source = self.store_path(request.get("path"))
            self.state.mkdir(parents=True, exist_ok=True)
            raw = self.state / f"image-{secrets.token_hex(4)}.tar"
            rewritten = raw.with_suffix(".load.tar")
            try:
                if source.is_file() and self.is_archive(source):
                    emit("err", f"reading image archive {source}\n")
                    shutil.copyfile(source, raw)
                elif source.is_file() and os.access(source, os.X_OK):
                    emit("err", f"streaming {source} in a confined container\n")
                    self.stream_image(source, raw)
                else:
                    refuse("expected an image archive or an image stream script in /nix/store")
                self.retag(raw, rewritten, tag)
                self.docker("load", "--input", str(rewritten), timeout=1800)
            finally:
                raw.unlink(missing_ok=True)
                rewritten.unlink(missing_ok=True)
        except BaseException:
            with self.lock:
                self.images.remove(tag)
            raise
        return {"image": tag}

    @staticmethod
    def store_path(path):
        if not isinstance(path, str):
            refuse("path is required")
        resolved = Path(os.path.realpath(path))
        if resolved.parts[:3] != ("/", "nix", "store") or len(resolved.parts) < 4:
            refuse(f"not a Nix store path: {path}")
        return resolved

    @staticmethod
    def is_archive(path):
        with open(path, "rb") as handle:
            head = handle.read(512)
        return head[:2] == b"\x1f\x8b" or head[:3] == b"BZh" or head[:6] == b"\xfd7zXZ\x00" or head[257:262] == b"ustar"

    def stream_image(self, script, output):
        # A stream script is the caller's build output, so it runs in a container like any
        # sandbox, never on the host, and only its stdout leaves.
        command = [
            self.args.docker,
            "run",
            "--rm",
            "--network",
            "none",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--read-only",
            "--tmpfs",
            "/tmp",
            "--pids-limit",
            "256",
            "--memory",
            "4g",
            "--cgroup-parent",
            "agent-sandbox.slice",
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "--volume",
            "/nix/store:/nix/store:ro",
            "--label",
            f"{OWNER_LABEL}={self.owner}",
            "--label",
            f"{KIND_LABEL}=image-stream",
            "--entrypoint",
            str(script),
            self.args.image,
        ]
        with open(output, "wb") as handle:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            written = 0
            try:
                while chunk := process.stdout.read(CHUNK):
                    written += len(chunk)
                    if written > MAX_IMAGE_BYTES:
                        process.kill()
                        refuse("image stream exceeds the size limit")
                    handle.write(chunk)
                stderr = process.stderr.read().decode(errors="replace")
                if process.wait(timeout=1800) != 0:
                    refuse(f"image stream failed: {stderr[-2000:]}")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    @staticmethod
    def retag(source, output, tag):
        """Copy a docker-archive, naming it only with the runner's tag.

        `docker load` applies whatever names an archive carries, so a crafted one could replace
        the sandbox image every launcher starts, or any other local image.
        """
        manifest = None
        with tarfile.open(source, "r:*") as archive, tarfile.open(output, "w") as rewritten:
            for member in archive:
                name = member.name.lstrip("./")
                if name in ("repositories", "index.json", "oci-layout"):
                    continue
                if name == "manifest.json":
                    data = json.load(archive.extractfile(member))
                    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
                        refuse("image archive must hold exactly one image")
                    data[0]["RepoTags"] = [tag]
                    manifest = json.dumps(data).encode()
                    info = tarfile.TarInfo("manifest.json")
                    info.size = len(manifest)
                    rewritten.addfile(info, io.BytesIO(manifest))
                    continue
                if (
                    not (member.isfile() or member.isdir())
                    or member.name.startswith("/")
                    or ".." in member.name.split("/")
                ):
                    refuse(f"unexpected archive member: {member.name}")
                rewritten.addfile(member, archive.extractfile(member) if member.isfile() else None)
        if manifest is None:
            refuse("image archive has no manifest.json")

    # Disposable sandboxes

    def allowed_image(self, image):
        if image is None:
            return self.args.image
        if image in self.images or TRUSTED_IMAGE_RE.match(image):
            if self.docker("image", "inspect", image, check=False).returncode != 0:
                refuse(f"image {image} is not loaded")
            return image
        refuse("image must be an agent-sandbox:<tag> image or a candidate this sandbox loaded")

    def free_port(self, port, taken):
        while port in taken or self.port_open(port):
            port += 1
        taken.add(port)
        return port

    @staticmethod
    def port_open(port):
        with socket.socket() as probe:
            probe.settimeout(0.2)
            return probe.connect_ex(("127.0.0.1", port)) == 0

    def sandbox_launch(self, request, emit):
        image = self.allowed_image(request.get("image"))
        worktree = request.get("worktree")
        pins = Pins(worktree, self.args.root)
        with self.lock:
            if len(self.sandboxes) >= MAX_SANDBOXES:
                pins.close()
                refuse(f"at most {MAX_SANDBOXES} disposable sandboxes per sandbox")
            name = f"agent-sandbox-run-{self.oid}-{secrets.token_hex(3)}"
            self.sandboxes[name] = {"pins": pins, "worktree": worktree, "touched": time.monotonic()}
        try:
            return self.create_sandbox(name, image, pins, worktree, request)
        except BaseException:
            with self.lock:
                self.sandboxes.pop(name, None)
            self.docker("rm", "--force", "--volumes", name, check=False)
            pins.close()
            shutil.rmtree(self.state / name, ignore_errors=True)
            raise

    def create_sandbox(self, name, image, pins, worktree, request):
        uid, gid = os.getuid(), os.getgid()
        runtime = f"/run/user/{uid}"
        home = os.environ["HOME"]
        root = self.state / name
        (root / "home").mkdir(parents=True)
        (root / "tmp").mkdir()
        args = [
            "--init",
            "--name",
            name,
            "--hostname",
            "agent-sandbox",
            "--user",
            f"{uid}:{gid}",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--security-opt",
            "seccomp=unconfined",
            "--security-opt",
            "systempaths=unconfined",
            "--pids-limit",
            "8192",
            "--cgroup-parent",
            "agent-sandbox.slice",
            "--oom-score-adj",
            "500",
            "--shm-size",
            "2g",
            "--label",
            f"{OWNER_LABEL}={self.owner}",
            "--label",
            f"{KIND_LABEL}=sandbox",
            "--mount",
            "type=bind,src=/sys/fs/cgroup/agent.slice/agent-sandbox.slice,dst=/run/agent-sandbox-cgroup,readonly",
            "--mount",
            "type=bind,src=/sys/fs/cgroup/agent.slice,dst=/run/agent-cgroup,readonly",
            "--volume",
            f"{root / 'tmp'}:/tmp",
            "--tmpfs",
            f"{runtime}:mode=0700,uid={uid},gid={gid}",
            "--volume",
            "/nix/store:/nix/store:ro",
            "--volume",
            "/nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket",
            "--volume",
            f"{self.args.passwd}:/etc/passwd:ro",
            "--volume",
            f"{self.args.group}:/etc/group:ro",
            "--volume",
            "/etc/localtime:/etc/localtime:ro",
            "--volume",
            f"{root / 'home'}:{home}",
            "--mount",
            f"type=bind,src={pins.worktree_source},dst={worktree}",
            "--workdir",
            worktree,
            "--env",
            f"HOME={home}",
            "--env",
            f"USER={os.environ.get('USER', 'user')}",
            "--env",
            f"XDG_RUNTIME_DIR={runtime}",
            "--env",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path={runtime}/bus",
            "--env",
            f"SWAYSOCK={runtime}/sway.sock",
            "--env",
            f"AGENT_SANDBOX_INSTANCE={name}",
            "--env",
            f"AGENT_SANDBOX_DISPLAY={'1' if request.get('display') else ''}",
            "--env",
            "AGENT_PREVIEW_PORTS=8080 8081 8082 8083 8084",
            "--interactive",
        ]
        if request.get("gpu", True):
            args += ["--device", "nvidia.com/gpu=all"]
            if self.args.gpu_lease_dir and os.path.isdir(self.args.gpu_lease_dir):
                args += ["--mount", f"type=bind,src={self.args.gpu_lease_dir},dst={self.args.gpu_lease_dir}"]
        if os.path.exists("/run/opengl-driver-32"):
            args += ["--volume", "/run/opengl-driver-32:/run/opengl-driver-32:ro"]
        ports = {}
        with open(self.args.ports_lock, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            taken = set()
            vnc = self.free_port(5900, taken)
            hyprland_vnc = self.free_port(vnc + 1, taken)
            novnc = self.free_port(6080, taken)
            publish = [
                "--publish",
                f"127.0.0.1:{vnc}:5900",
                "--publish",
                f"127.0.0.1:{hyprland_vnc}:5901",
                "--publish",
                f"127.0.0.1:{novnc}:6080",
                "--env",
                f"AGENT_SANDBOX_VNC_URL=http://127.0.0.1:{novnc}/vnc.html?autoconnect=1&resize=scale",
            ]
            host_port = 18080
            for port in PREVIEW_PORTS:
                host_port = self.free_port(host_port, taken)
                url = f"http://{self.args.preview_address}:{host_port}"
                ports[port] = url
                publish += ["--publish", f"{host_port}:{port}", "--env", f"AGENT_PREVIEW_URL_{port}={url}"]
            self.docker("create", *args, *publish, image, "sleep", "infinity", timeout=120)
        self.docker("start", name, timeout=120)
        emit("err", f"started {name}\n")
        for _ in range(300):
            if self.docker("exec", name, "test", "-s", f"{runtime}/sshd_config", check=False).returncode == 0:
                break
            state = self.docker(
                "container", "inspect", "--format", "{{.State.Running}}", name, check=False
            ).stdout.strip()
            if state != "true":
                logs = self.docker("logs", "--tail", "50", name, check=False)
                refuse(f"{name} exited during startup:\n{logs.stdout}{logs.stderr}")
            time.sleep(0.2)
        address = self.docker(
            "container", "inspect", "--format", "{{.NetworkSettings.IPAddress}}", name, check=False
        ).stdout.strip()
        return {
            "id": name,
            "image": image,
            "worktree": worktree,
            "address": address,
            "vnc_url": f"http://127.0.0.1:{novnc}/vnc.html?autoconnect=1&resize=scale",
            "preview_urls": {str(port): url for port, url in ports.items()},
        }

    def sandbox(self, request):
        name = request.get("id")
        with self.lock:
            if name not in self.sandboxes:
                refuse(f"no disposable sandbox {name!r} belongs to this sandbox")
            self.sandboxes[name]["touched"] = time.monotonic()
            return name, self.sandboxes[name]

    def sandbox_exec(self, request, emit):
        name, sandbox = self.sandbox(request)
        argv = request.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(arg, str) for arg in argv):
            refuse("argv must be a non-empty list of strings")
        timeout = self.timeout(request)
        args = [
            "exec",
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "--workdir",
            request.get("cwd") or sandbox["worktree"],
        ]
        for item in request.get("env") or []:
            if not isinstance(item, str) or not ENV_RE.match(item):
                refuse(f"env entries must be NAME=value: {item!r}")
            args += ["--env", item]
        # timeout runs inside the sandbox, so the command itself stops, not only docker's client.
        args += [name, "timeout", "--kill-after=10", str(timeout), *argv]
        return {"exit": self.stream([self.args.docker, *args], emit, timeout + 30)}

    def sandbox_logs(self, request, emit):
        name, _ = self.sandbox(request)
        tail = str(min(int(request.get("tail") or 200), MAX_OUTPUT_LINES))
        return {"exit": self.stream([self.args.docker, "logs", "--tail", tail, name], emit, 60)}

    def sandbox_rm(self, request, emit):
        name, sandbox = self.sandbox(request)
        self.docker("rm", "--force", "--volumes", name, check=False)
        sandbox["pins"].close()
        root = self.state / name
        subprocess.run(["chmod", "-R", "u+w", str(root)], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)
        with self.lock:
            self.sandboxes.pop(name, None)
        return {"removed": name}

    def ls(self, request, emit):
        with self.lock:
            return {
                "owner": self.owner,
                "sandboxes": [{"id": name, "worktree": entry["worktree"]} for name, entry in self.sandboxes.items()],
                "projects": [{"project": name, "worktree": entry["worktree"]} for name, entry in self.projects.items()],
                "images": list(self.images),
            }

    # Compose

    def project_name(self, request):
        name = request.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            refuse("compose name must be lowercase letters, digits and dashes, at most 24 characters")
        return f"asr-{self.oid}-{name}"

    def compose_project(self, request, emit):
        return {"project": self.project_name(request)}

    def compose_lock(self, project):
        with self.lock:
            return self.project_locks.setdefault(project, threading.Lock())

    def compose_submit(self, project, request):
        model = request.get("model")
        worktree = request.get("worktree")
        if not isinstance(model, dict):
            refuse("model must be the JSON output of docker compose config")
        pins = Pins(worktree, self.args.root)
        try:
            labels = {**self.base_labels, KIND_LABEL: "compose", PROJECT_LABEL: project}
            validated = ComposeModel(model, project, pins, labels).validate()
        except BaseException:
            pins.close()
            raise
        directory = self.state / "compose" / project
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "compose.json").write_text(json.dumps(validated, indent=2))
        with self.lock:
            previous = self.projects.get(project)
            if previous is None and len(self.projects) >= MAX_PROJECTS:
                pins.close()
                refuse(f"at most {MAX_PROJECTS} compose projects per sandbox; bring one down first")
            self.projects[project] = {
                "pins": pins,
                "worktree": worktree,
                "dir": directory,
                "model": validated,
                "touched": time.monotonic(),
            }
        if previous is not None:
            previous["pins"].close()
        return self.projects[project]

    def registered(self, project):
        with self.lock:
            if project not in self.projects:
                refuse(f"compose project {project} is not up in this sandbox; run build or up first")
            self.projects[project]["touched"] = time.monotonic()
            return self.projects[project]

    def compose_command(self, entry, project, *argv):
        """Run Compose's client in a namespace that holds only this worktree and the store.

        The client reads build contexts, Dockerfiles and secret files itself, so a symlink in the
        worktree pointing elsewhere on the host finds nothing there.
        """
        pins = entry["pins"]
        command = [
            self.args.bwrap,
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--clearenv",
            "--setenv",
            "HOME",
            "/tmp",
            "--setenv",
            "PATH",
            "/var/empty",
            "--setenv",
            "DOCKER_HOST",
            "unix:///run/docker.sock",
            "--setenv",
            "COMPOSE_BAKE",
            "false",
            "--setenv",
            "DOCKER_CLI_HINTS",
            "false",
            "--ro-bind",
            "/nix/store",
            "/nix/store",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--tmpfs",
            "/tmp",
            "--bind",
            self.args.docker_socket,
            "/run/docker.sock",
            "--ro-bind",
            str(entry["dir"]),
            str(entry["dir"]),
            "--bind-fd",
            str(pins.fd),
            pins.worktree,
            "--chdir",
            str(entry["dir"]),
            self.args.compose,
            "--project-name",
            project,
            "--file",
            str(entry["dir"] / "compose.json"),
            "--project-directory",
            str(entry["dir"]),
            *argv,
        ]
        return command, (pins.fd,)

    def compose_up(self, request, emit):
        project = self.project_name(request)
        with self.compose_lock(project):
            entry = self.compose_submit(project, request)
            argv = ["up", "--detach", "--remove-orphans"]
            if request.get("build"):
                argv.append("--build")
            if request.get("wait"):
                argv += ["--wait", "--wait-timeout", str(self.timeout(request))]
            argv += self.services(request, entry)
            command, fds = self.compose_command(entry, project, *argv)
            code = self.stream(command, emit, self.timeout(request) + 60, fds)
            self.connect_owner(project)
            return {"exit": code, "project": project, "services": self.compose_ps_data(project)}

    def compose_build(self, request, emit):
        project = self.project_name(request)
        with self.compose_lock(project):
            entry = self.compose_submit(project, request)
            command, fds = self.compose_command(entry, project, "build", *self.services(request, entry))
            return {"exit": self.stream(command, emit, self.timeout(request), fds), "project": project}

    def compose_ps(self, request, emit):
        project = self.project_name(request)
        self.registered(project)
        return {"project": project, "services": self.compose_ps_data(project)}

    def compose_logs(self, request, emit):
        project = self.project_name(request)
        entry = self.registered(project)
        tail = str(min(int(request.get("tail") or 200), MAX_OUTPUT_LINES))
        command, fds = self.compose_command(
            entry, project, "logs", "--no-color", "--tail", tail, *self.services(request, entry)
        )
        return {"exit": self.stream(command, emit, 120, fds)}

    def compose_exec(self, request, emit):
        project = self.project_name(request)
        entry = self.registered(project)
        service = request.get("service")
        if service not in entry["model"]["services"]:
            refuse(f"no service {service!r} in {project}")
        argv = request.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(arg, str) for arg in argv):
            refuse("argv must be a non-empty list of strings")
        args = ["exec", "--no-tty"]
        if request.get("user"):
            args += ["--user", str(request["user"])]
        if request.get("cwd"):
            args += ["--workdir", str(request["cwd"])]
        for item in request.get("env") or []:
            if not isinstance(item, str) or not ENV_RE.match(item):
                refuse(f"env entries must be NAME=value: {item!r}")
            args += ["--env", item]
        command, fds = self.compose_command(entry, project, *args, service, *argv)
        return {"exit": self.stream(command, emit, self.timeout(request), fds)}

    def compose_down(self, request, emit):
        project = self.project_name(request)
        self.registered(project)
        with self.compose_lock(project):
            return self.compose_down_locked(project, emit=emit)

    def compose_down_locked(self, project, emit=None, quiet=False):
        with self.lock:
            entry = self.projects.get(project)
        code = 0
        if entry is not None:
            for network in self.owned("network", f"label={PROJECT_LABEL}={project}"):
                self.disconnect_owner(network)
            command, fds = self.compose_command(
                entry, project, "down", "--volumes", "--remove-orphans", "--rmi", "local", "--timeout", "10"
            )
            code = self.stream(command, emit or (lambda *_: None), 600, fds)
        self.remove_owned(f"label={PROJECT_LABEL}={project}")
        with self.lock:
            entry = self.projects.pop(project, None)
        if entry is not None:
            entry["pins"].close()
            shutil.rmtree(entry["dir"], ignore_errors=True)
        return {"exit": code, "project": project, "removed": True}

    def connect_owner(self, project):
        # Docker isolates bridge networks from each other, so the caller joins the stack's networks
        # to reach its services by address.
        for network in self.owned("network", f"label={PROJECT_LABEL}={project}"):
            self.docker("network", "connect", network, self.owner, check=False)

    def compose_ps_data(self, project):
        ids = self.owned("ps", f"label={PROJECT_LABEL}={project}")
        if not ids:
            return []
        inspected = json.loads(self.docker("container", "inspect", *ids).stdout)
        services = []
        for container in inspected:
            labels = container["Config"]["Labels"] or {}
            networks = container["NetworkSettings"]["Networks"] or {}
            state = container["State"]
            services.append(
                {
                    "service": labels.get("com.docker.compose.service"),
                    "container": container["Name"].lstrip("/"),
                    "state": state.get("Status"),
                    "health": (state.get("Health") or {}).get("Status"),
                    "exit_code": state.get("ExitCode"),
                    "addresses": {name: net.get("IPAddress") for name, net in networks.items()},
                    "ports": {
                        port: [f"{b['HostIp']}:{b['HostPort']}" for b in bindings or []]
                        for port, bindings in (container["NetworkSettings"].get("Ports") or {}).items()
                    },
                }
            )
        return sorted(services, key=lambda item: (item["service"] or "", item["container"]))

    @staticmethod
    def services(request, entry):
        names = request.get("services") or []
        for name in names:
            if name not in entry["model"]["services"]:
                refuse(f"no service {name!r} in this project")
        return list(names)

    @staticmethod
    def timeout(request):
        value = int(request.get("timeout") or DEFAULT_TIMEOUT)
        if not 0 < value <= MAX_TIMEOUT:
            refuse(f"timeout must be between 1 and {MAX_TIMEOUT} seconds")
        return value

    def stream(self, command, emit, timeout, fds=()):
        process = subprocess.Popen(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=fds
        )
        deadline = time.monotonic() + timeout
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "out")
        selector.register(process.stderr, selectors.EVENT_READ, "err")
        open_streams = 2
        try:
            while open_streams:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    emit("err", f"sandbox-runner: timed out after {timeout} s\n")
                    process.kill()
                    break
                for key, _ in selector.select(min(remaining, 1)):
                    data = os.read(key.fileobj.fileno(), CHUNK)
                    if not data:
                        selector.unregister(key.fileobj)
                        open_streams -= 1
                        continue
                    emit(key.data, data.decode(errors="replace"))
            return process.wait(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            selector.close()


OPERATIONS = {
    "ls": "ls",
    "image.load": "image_load",
    "sandbox.launch": "sandbox_launch",
    "sandbox.exec": "sandbox_exec",
    "sandbox.logs": "sandbox_logs",
    "sandbox.rm": "sandbox_rm",
    "compose.project": "compose_project",
    "compose.build": "compose_build",
    "compose.up": "compose_up",
    "compose.ps": "compose_ps",
    "compose.logs": "compose_logs",
    "compose.exec": "compose_exec",
    "compose.down": "compose_down",
}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        runner = self.server.runner
        write_lock = threading.Lock()

        def send(message):
            data = (json.dumps(message) + "\n").encode()
            with write_lock:
                self.wfile.write(data)
                self.wfile.flush()

        def emit(stream, text):
            send({stream: text})

        try:
            line = self.rfile.readline(MAX_REQUEST + 1)
            if len(line) > MAX_REQUEST:
                refuse("request too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                refuse("request must be a JSON object")
            operation = OPERATIONS.get(request.get("op"))
            if operation is None:
                refuse(f"unknown operation {request.get('op')!r}; allowed: {', '.join(sorted(OPERATIONS))}")
            send({"result": getattr(runner, operation)(request, emit)})
        except Refused as error:
            send({"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (ValueError, TypeError, KeyError) as error:
            send({"error": f"bad request: {error}"})
        except subprocess.TimeoutExpired as error:
            send({"error": f"timed out: {error}"})


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def __init__(self, path, runner):
        self.runner = runner
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        if os.path.exists(path):
            os.unlink(path)
        super().__init__(path, Handler)
        os.chmod(path, 0o600)

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


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="agent-sandbox-runner")
    parser.add_argument("--owner", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--passwd", required=True)
    parser.add_argument("--group", required=True)
    parser.add_argument("--ports-lock", required=True)
    parser.add_argument("--preview-address", default="127.0.0.1")
    parser.add_argument("--gpu-lease-dir")
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--compose", default="docker-compose")
    parser.add_argument("--bwrap", default="bwrap")
    parser.add_argument("--docker-socket", default="/run/docker.sock")
    parser.add_argument("--ttl", type=int, default=12 * 3600, help="seconds a sandbox or stack may sit idle")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    runner = Runner(args)
    runner.sweep_orphans()
    runner.state.mkdir(parents=True, exist_ok=True)
    (runner.state / "owner").write_text(args.owner + "\n")
    (runner.state / "pid").write_text(f"{os.getpid()}\n")
    server = Server(args.socket, runner)
    threading.Thread(target=runner.reap, daemon=True).start()

    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        runner.cleanup()
        try:
            os.unlink(args.socket)
        except OSError:
            pass


if __name__ == "__main__":
    main(sys.argv[1:])
