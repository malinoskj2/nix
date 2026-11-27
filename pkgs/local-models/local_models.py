#!/usr/bin/env python3
"""Host-only, pinned model reconciliation and pruning. No inference."""

import argparse
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

DIGEST = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".publish-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def link(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(source)
    temporary.replace(destination)


def relative(value):
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts or value == ".":
        raise ValueError(f"Unsafe relative path: {value}")
    return path


def validate(catalog):
    entries = catalog["entries"]
    stores = catalog.get("stores")
    if stores is not None:
        for name, path in stores.items():
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or not Path(path).is_absolute():
                raise ValueError(f"Invalid store: {name}")
        if catalog.get("defaultStore") not in stores:
            raise ValueError("defaultStore must name a declared store")
    for name in catalog.get("mountedStores", []):
        if name not in (stores or {}):
            raise ValueError(f"Unknown mounted store: {name}")
    for name, reserve in catalog.get("storeReserves", {}).items():
        if name not in (stores or {}) or not isinstance(reserve, int) or reserve < 0:
            raise ValueError(f"Invalid store reserve: {name}")
    visiting, done, order = set(), set(), []

    def visit(alias):
        if alias in visiting:
            raise ValueError(f"Dependency cycle: {alias}")
        if alias in done:
            return
        if alias not in entries:
            raise ValueError(f"Missing dependency: {alias}")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", alias):
            raise ValueError(f"Invalid alias: {alias}")
        visiting.add(alias)
        entry = entries[alias]
        if "store" in entry and entry["store"] not in (stores or {}):
            raise ValueError(f"Unknown store for {alias}: {entry['store']}")
        if entry["kind"] == "adapter" and not entry.get("unresolved"):
            if entry.get("base") not in entry.get("dependencies", []):
                raise ValueError(f"Adapter needs an explicit base dependency: {alias}")
            if not entry.get("loader"):
                raise ValueError(f"Adapter needs loader instructions: {alias}")
        targets = set()
        for file in entry["files"]:
            relative(file["target"])
            if file["target"] in targets:
                raise ValueError(f"Duplicate target in {alias}")
            targets.add(file["target"])
            if file.get("storePath"):
                if not file["storePath"].startswith("/nix/store/"):
                    raise ValueError("Packaged assets must come from the Nix store")
                continue
            relative(file["path"])
            if file.get("url"):
                if not file["url"].startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", file.get("sha256", "")):
                    raise ValueError("Standalone files need HTTPS and SHA-256")
            elif not (
                re.fullmatch(r"[0-9a-f]{40}", file["revision"]) and re.fullmatch(r"[^/]+/[^/]+", file["repository"])
            ):
                raise ValueError("Hub files need a repository and immutable revision")
            digest = file.get("sha256") or file.get("gitSha1", "")
            if not re.fullmatch(r"[0-9a-f]{64}|[0-9a-f]{40}", digest) or file["size"] < 0:
                raise ValueError("Files need expected sizes and hashes")
        for dependency in entry.get("dependencies", []):
            visit(dependency)
        if entry.get("baseSources"):
            base = entries[entry["base"]]
            actual = {(f.get("repository"), f.get("revision")) for f in base["files"]}
            expected = {(f["repository"], f["revision"]) for f in entry["baseSources"]}
            if actual != expected:
                raise ValueError(f"Adapter base revision differs from its verified selection: {alias}")
        visiting.remove(alias)
        done.add(alias)
        order.append(alias)

    for alias, entry in entries.items():
        if any(dep not in entry.get("dependencies", []) for dep in entry.get("views", {}).values()):
            raise ValueError(f"Views must declare dependencies: {alias}")
        for name in entry.get("views", {}):
            relative(name)
        visit(alias)
    return order


def wanted_aliases(entries):
    wanted = {alias for alias, entry in entries.items() if entry.get("enabled", True)}
    pending = list(wanted)
    while pending:
        for dependency in entries[pending.pop()].get("dependencies", []):
            if dependency not in wanted:
                wanted.add(dependency)
                pending.append(dependency)
    return wanted


def split(catalog):
    """Consumer catalog of enabled entries and their dependencies; disabled entries are only retained."""
    validate(catalog)
    wanted = wanted_aliases(catalog["entries"])
    entries = catalog["entries"].items()
    # Activation links the two files separately; pruning needs both from one generation.
    generation = fingerprint(catalog)
    consumer = {
        **catalog,
        "generation": generation,
        "entries": {a: {**e, "enabled": True} for a, e in entries if a in wanted},
    }
    retained = {
        "generation": generation,
        "entries": {a: {**e, "enabled": False} for a, e in entries if a not in wanted},
    }
    return consumer, retained


def norm(path):
    path = os.path.abspath(path)
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))


def human(size):
    for unit in ["B", "KiB", "MiB", "GiB"]:
        if size < 1024 or unit == "GiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{size} B"
        size /= 1024


def open_files():
    """Inodes held open or mapped by processes this user can inspect."""
    handles, mapped = {}, {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                try:
                    stat = os.stat(f"/proc/{pid}/fd/{fd}")
                except OSError:
                    continue
                handles.setdefault((stat.st_dev, stat.st_ino), pid)
        except OSError:
            pass
        try:
            with open(f"/proc/{pid}/maps") as maps:
                for line in maps:
                    fields = line.split(maxsplit=5)
                    if len(fields) == 6 and fields[4] != "0":
                        mapped.setdefault(int(fields[4]), pid)
        except (OSError, ValueError):
            pass

    def holder(stat):
        # Mapped inodes are matched without the device, which errs towards deferring.
        return handles.get((stat.st_dev, stat.st_ino)) or mapped.get(stat.st_ino)

    return holder


class Sync:
    def __init__(self, root, catalog, downloader=None, retained=None, prune=True, readonly=False, holders=None):
        self.root, self.catalog = Path(root), catalog
        self.downloader = downloader or self.download
        retained = (retained or {}).get("entries", {})
        if set(retained) & set(catalog["entries"]):
            raise ValueError("Retained entries must not also be in the catalog")
        self.full = {
            **catalog,
            "entries": {**catalog["entries"], **{a: {**e, "enabled": False} for a, e in retained.items()}},
        }
        self.order = validate(self.full)
        self.wanted = wanted_aliases(self.full["entries"])
        self.prune_after = prune
        self.holders = holders or open_files
        self.stores = {name: Path(path) for name, path in catalog.get("stores", {"root": str(self.root)}).items()}
        self.default_store = catalog.get("defaultStore", "root")
        self.mounted = {self.stores[name] for name in catalog.get("mountedStores", [])}
        self.reserves = {self.stores[name]: size for name, size in catalog.get("storeReserves", {}).items()}
        self.pinned = {}
        self.state = self.root / ".state"
        if not readonly:
            self.state.mkdir(parents=True, exist_ok=True)
        self.stamps_path = self.state / "verified.json"
        self.stamps = json.loads(self.stamps_path.read_text()) if self.stamps_path.exists() else {}
        self.token = False
        credential = os.environ.get("CREDENTIALS_DIRECTORY")
        if credential and (Path(credential) / "hf-token").is_file():
            self.token = (Path(credential) / "hf-token").read_text().strip()
            if self.token == "unconfigured":
                self.token = False
            if self.token and not re.fullmatch(r"hf_[A-Za-z0-9]+", self.token):
                print(
                    "Invalid host HF credential format; public downloads continue without authentication",
                    file=sys.stderr,
                )
                self.token = False
            os.environ["HF_TOKEN_PATH"] = str(Path(credential) / "hf-token")
        os.environ.pop("HF_TOKEN", None)
        if not self.token:
            self.token = False
            os.environ.pop("HF_TOKEN_PATH", None)

    def store(self, entry):
        return self.stores[entry.get("store", self.default_store)]

    def headroom(self, store):
        return max(2 * 1024**3, self.reserves.get(store, 0))

    def present(self, store):
        """A mounted store counts only while its filesystem is mounted, never its empty mount point.

        The filesystem found is pinned; `verify` refuses work once the path leads elsewhere."""
        if store not in self.mounted:
            return store.is_dir()
        try:
            os.listdir(store)
            if not os.path.ismount(store):
                return False
            stat = os.stat(store)
        except OSError:
            return False
        self.pinned[store] = (stat.st_dev, stat.st_ino)
        return True

    def verify(self, store, path=None):
        if store not in self.mounted:
            return
        stat = os.stat(store)
        pinned = self.pinned.get(store)
        if pinned != (stat.st_dev, stat.st_ino) or not os.path.ismount(store):
            raise OSError(errno.ESTALE, f"Mounted store {store} changed since it was checked")
        if path is not None and os.stat(path).st_dev != pinned[0]:
            raise OSError(errno.EXDEV, f"{path} is outside mounted store {store}")

    def available(self, store):
        if store in self.mounted:
            return self.present(store) and os.access(store, os.W_OK)
        try:
            store.mkdir(parents=True, exist_ok=True)
        except OSError:
            return False
        return os.access(store, os.W_OK)

    def destination(self, file, store=None):
        store = store or self.store({})
        if file.get("storePath"):
            return Path(file["storePath"])
        if file.get("url"):
            return store / "files" / file["sha256"] / file["path"]
        return (
            store
            / "huggingface"
            / ("models--" + file["repository"].replace("/", "--"))
            / "snapshots"
            / file["revision"]
            / file["path"]
        )

    def valid(self, path, file):
        if not path.is_file():
            return False
        if file.get("storePath"):
            return True  # Nix verifies store contents.
        stat = path.stat()
        if stat.st_size != file["size"]:
            return False
        expected = file.get("sha256") or file["gitSha1"]
        signature = [
            str(path.resolve()),
            stat.st_dev,
            stat.st_ino,
            stat.st_size,
            stat.st_mtime_ns,
            stat.st_ctime_ns,
            expected,
        ]
        if self.stamps.get(str(path)) == signature:
            return True
        digest = hashlib.sha256() if "sha256" in file else hashlib.sha1()
        if "gitSha1" in file:
            digest.update(f"blob {stat.st_size}\0".encode())
        with path.open("rb") as handle:
            while block := handle.read(8 * 1024**2):
                digest.update(block)
        after = path.stat()
        unchanged = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns) == (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if digest.hexdigest() != expected or not unchanged:
            return False
        self.stamps[str(path)] = signature
        return True

    def import_file(self, file, destination, store):
        digest = file.get("sha256") or file["gitSha1"]
        others = [store] + [s for s in self.stores.values() if s != store]
        candidates = [Path(p) for p in file.get("imports", [])]
        candidates += [s / "files" / digest / "imported" for s in others]
        candidates += [self.destination(file, s) for s in others[1:]]
        if file.get("repository"):
            # Reuse another complete revision's content-addressed blob, offline.
            repo = "models--" + file["repository"].replace("/", "--")
            candidates += [s / "huggingface" / repo / "blobs" / digest for s in others]
            for cache in self.catalog.get("importCaches", []):
                candidates.append(Path(cache) / repo / "snapshots" / file["revision"] / file["path"])
        for source in candidates:
            try:
                if not self.valid(source, file):
                    continue
            except OSError:
                if source.is_relative_to(store):
                    raise
                print(f"import: skipped unreadable {source}", file=sys.stderr, flush=True)
                continue
            if any(source.resolve().is_relative_to((store / d).resolve()) for d in ["huggingface", "files"]):
                # Already managed immutable content in this store: repair a snapshot link without a copy.
                link(source.resolve(), destination)
                return True
            # Reflink if possible, otherwise copy. Never hardlink mutable project weights.
            # This leaves original consumers and other stores intact and imports no external symlinks.
            blob = store / "files" / digest / "imported"
            blob.parent.mkdir(parents=True, exist_ok=True)
            if not self.valid(blob, file):
                if shutil.disk_usage(store).free < file["size"] + self.headroom(store):
                    raise OSError("Insufficient space to safely import project weights")
                temporary = blob.with_suffix(".importing")
                try:
                    subprocess.run(["cp", "--reflink=auto", "--", str(source.resolve()), str(temporary)], check=True)
                except subprocess.CalledProcessError:
                    # A read error in the source is skipped; a write error recurs in the download.
                    temporary.unlink(missing_ok=True)
                    continue
                if not self.valid(temporary, file):
                    temporary.unlink(missing_ok=True)
                    continue
                temporary.replace(blob)
            link(blob, destination)
            return True
        return False

    def download(self, file, store):
        if file.get("url"):
            destination = self.destination(file, store)
            destination.parent.mkdir(parents=True, exist_ok=True)
            partial = destination.with_suffix(destination.suffix + ".part")
            subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--location",
                    "--retry",
                    "3",
                    "--connect-timeout",
                    "30",
                    "--continue-at",
                    "-",
                    "--output",
                    str(partial),
                    file["url"],
                ],
                check=True,
            )
            if not self.valid(partial, file):
                partial.rename(partial.with_name(partial.name + f".damaged-{time.time_ns()}"))
                raise ValueError("Standalone checksum mismatch")
            partial.replace(destination)
            return destination
        from huggingface_hub import hf_hub_download

        return Path(
            hf_hub_download(
                repo_id=file["repository"],
                revision=file["revision"],
                filename=file["path"],
                cache_dir=str(store / "huggingface"),
                token=self.token,
            )
        )

    def obtain(self, file, store):
        self.verify(store)
        destination = self.place(file, store)
        if not file.get("storePath"):
            self.verify(store, destination)
        return destination

    def place(self, file, store):
        destination = self.destination(file, store)
        if self.valid(destination, file):
            return destination
        if file.get("storePath"):
            raise FileNotFoundError("Packaged asset missing")
        if self.import_file(file, destination, store):
            return destination
        if shutil.disk_usage(store).free < file["size"] + self.headroom(store):
            raise OSError("Insufficient free disk space including download headroom")
        # Preserve a damaged cache blob for inspection; let Hub fetch only this file.
        if destination.exists():
            blob = destination.resolve()
            if blob.is_relative_to(store):
                blob.rename(blob.with_name(blob.name + f".damaged-{time.time_ns()}"))
            destination.unlink(missing_ok=True)
        self.verify(store)
        downloaded = self.downloader(file, store)
        if not self.valid(downloaded, file):
            raise ValueError("Downloaded file failed size/hash verification")
        if downloaded != destination:
            link(downloaded, destination)
        return destination

    def reconcile(self):
        report = {}
        for alias in self.order:
            if alias not in self.wanted:
                continue
            entry = self.full["entries"][alias]
            store = self.store(entry)
            item = {
                "path": str(self.root / "by-name" / alias),
                "store": entry.get("store", self.default_store),
                "kind": entry["kind"],
                "compatibility": entry.get("compatibility", "unverified"),
                "files": [],
                "consumerReady": False,
            }
            report[alias] = item
            if entry.get("unresolved"):
                item.update(status="unresolved", reason=entry["unresolved"])
                continue
            if any(not f.get("storePath") for f in entry["files"]) and not self.available(store):
                item.update(status="missing", reason=f"Store {item['store']} at {store} is unavailable")
                print(f"{alias}: store {item['store']} unavailable", file=sys.stderr, flush=True)
                continue
            for file in entry["files"]:
                try:
                    destination = self.obtain(file, store)
                    item["files"].append({"target": file["target"], "path": str(destination), "status": "ready"})
                except Exception as error:
                    # Never log exception bodies/URLs: Hub errors may contain request details.
                    status = "blocked" if entry.get("gated") else "missing"
                    item["files"].append({"target": file["target"], "status": status, "error": type(error).__name__})
                    print(f"{alias}: {file['target']}: {status} ({type(error).__name__})", file=sys.stderr, flush=True)
            failed = [f for f in item["files"] if f["status"] != "ready"]
            if failed:
                item["status"] = "blocked" if entry.get("gated") else "missing"
                item["reason"] = (
                    "Check host credential and repository access"
                    if entry.get("gated")
                    else "Required files missing or failed verification; inspect service logs"
                )
            elif any(report[d]["status"] != "ready" for d in entry.get("dependencies", [])):
                item.update(status="unresolved", reason="Required dependency is not ready")
            else:
                dependency_views = {
                    name: (self.root / "by-name" / dep).resolve(strict=True)
                    for name, dep in entry.get("views", {}).items()
                }
                identity = hashlib.sha256(
                    json.dumps(
                        [
                            (f["target"], f.get("sha256"), f.get("gitSha1"), f.get("revision"), f.get("storePath"))
                            for f in entry["files"]
                        ],
                        sort_keys=True,
                    ).encode()
                    + json.dumps(entry.get("referencePreparation"), sort_keys=True).encode()
                    + json.dumps({name: str(path) for name, path in dependency_views.items()}, sort_keys=True).encode()
                ).hexdigest()
                try:
                    for file in entry["files"]:
                        if not file.get("storePath"):
                            self.verify(store, self.destination(file, store))
                except OSError as error:
                    item.update(status="missing", reason=f"Store changed before publication: {type(error).__name__}")
                    continue
                view = self.root / "views" / alias / identity
                view.mkdir(parents=True, exist_ok=True)
                for file in entry["files"]:
                    link(self.destination(file, store), view / file["target"])
                if entry.get("referencePreparation"):
                    try:
                        prepare_reference(view, entry["referencePreparation"])
                    except Exception as error:
                        item.update(status="missing", reason=f"Reference preparation failed: {type(error).__name__}")
                        continue
                for name, dependency_view in dependency_views.items():
                    link(dependency_view, view / relative(name))
                link(view, self.root / "by-name" / alias)
                item.update(
                    status="ready",
                    consumerReady=entry.get("compatibility") == "validated"
                    and all(report[dep]["consumerReady"] for dep in entry.get("dependencies", [])),
                )
            atomic_json(self.stamps_path, self.stamps)
            atomic_json(
                self.root / "readiness.json",
                {
                    "catalogFingerprint": fingerprint(self.catalog),
                    "updatedAt": time.time(),
                    "entries": report,
                    "complete": False,
                },
            )
        complete = all(v["status"] == "ready" for v in report.values())
        failed = []
        for alias, item in report.items():
            if item["status"] == "ready":
                continue
            if item["status"] != "unresolved":
                failed.append(alias)
            print(f"{alias}: {item['status']}: {item.get('reason', '')}", file=sys.stderr, flush=True)
        if failed:
            print(f"Sync failed for {len(failed)} entries: {', '.join(failed)}", file=sys.stderr, flush=True)
        atomic_json(
            self.root / "readiness.json",
            {
                "catalogFingerprint": fingerprint(self.catalog),
                "updatedAt": time.time(),
                "entries": report,
                "complete": complete,
            },
        )
        pruned = self.prune() if self.prune_after else True
        return not failed and pruned

    def entry_store_paths(self, aliases):
        """Per store directory: Hub repository folder to revisions, and content digests."""
        repos, digests = {}, {}
        for alias in aliases:
            entry = self.full["entries"][alias]
            store = norm(self.store(entry))
            for file in entry["files"]:
                if file.get("storePath"):
                    continue
                digests.setdefault(store, set()).add(file.get("sha256") or file["gitSha1"])
                if not file.get("url"):
                    repo = "models--" + file["repository"].replace("/", "--")
                    repos.setdefault(store, {}).setdefault(repo, set()).add(file["revision"])
        return repos, digests

    def managed_repositories(self):
        """Hub folders this store has ever been responsible for; other tools may share HF_HUB_CACHE."""
        path = self.state / "managed.json"
        if path.exists():
            managed = set(json.loads(path.read_text())["repositories"])
        else:
            managed = set()
            for key in self.stamps:
                parts = Path(key).parts
                if "huggingface" in parts and parts.index("huggingface") + 1 < len(parts):
                    candidate = parts[parts.index("huggingface") + 1]
                    if candidate.startswith("models--"):
                        managed.add(candidate)
        for entry in self.full["entries"].values():
            for file in entry["files"]:
                if file.get("repository") and not file.get("url") and not file.get("storePath"):
                    managed.add("models--" + file["repository"].replace("/", "--"))
        return managed

    def prune_plan(self):
        retained = set(self.full["entries"]) - self.wanted
        stores = {}
        for name, path in self.stores.items():
            if self.present(path):
                stores.setdefault(norm(path), name)
        repos, digests = self.entry_store_paths(self.full["entries"])
        managed = self.managed_repositories()
        views, by_name = norm(self.root / "views"), norm(self.root / "by-name")
        areas = [views, by_name] + [os.path.join(s, d) for s in stores for d in ["huggingface", "files"]]

        def inside(path, area):
            return path == area or path.startswith(area + os.sep)

        live = set()

        def mark(path):
            path = norm(path)
            while path not in live:
                live.add(path)
                if not any(inside(path, area) for area in areas):
                    return
                if os.path.islink(path):
                    path = norm(os.path.join(os.path.dirname(path), os.readlink(path)))
                elif os.path.isdir(path):
                    for child in os.scandir(path):
                        mark(child.path)
                    return
                else:
                    return

        for alias in self.wanted:
            if os.path.lexists(os.path.join(by_name, alias)):
                mark(os.path.join(by_name, alias))
        for alias in retained:
            if os.path.isdir(os.path.join(views, alias)):
                for view in os.scandir(os.path.join(views, alias)):
                    mark(view.path)
        for alias in self.wanted | retained:
            entry = self.full["entries"][alias]
            for file in entry["files"]:
                if not file.get("storePath"):
                    mark(self.destination(file, self.store(entry)))

        plan = []

        def tree_size(path):
            if os.path.islink(path) or not os.path.isdir(path):
                return os.lstat(path).st_size if not os.path.islink(path) else 0
            return sum(
                os.lstat(os.path.join(d, f)).st_size
                for d, _, files in os.walk(path)
                for f in files
                if not os.path.islink(os.path.join(d, f))
            )

        def add(path, reason):
            plan.append((path, tree_size(path), reason))

        def files_below(path):
            for directory, dirnames, filenames in os.walk(path):
                for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(directory, d))]:
                    yield norm(os.path.join(directory, name))

        if os.path.isdir(by_name):
            for link_entry in os.scandir(by_name):
                if link_entry.is_symlink() and link_entry.name not in self.wanted:
                    reason = "alias disabled" if link_entry.name in retained else "alias no longer in catalog"
                    add(norm(link_entry.path), reason)
        if os.path.isdir(views):
            for alias_dir in os.scandir(views):
                if alias_dir.name in retained or not alias_dir.is_dir(follow_symlinks=False):
                    continue
                for view in os.scandir(alias_dir.path):
                    if norm(view.path) not in live:
                        reason = "superseded view" if alias_dir.name in self.wanted else "alias no longer in catalog"
                        add(norm(view.path), reason)

        def moved(store, key, table):
            other = [stores[s] for s in stores if s != store and key in table.get(s, {})]
            return f"entry moved to store {other[0]}" if other else None

        for store in stores:
            hub = os.path.join(store, "huggingface")
            for repo in sorted(os.listdir(hub)) if os.path.isdir(hub) else []:
                if repo not in managed or os.path.islink(os.path.join(hub, repo)):
                    continue
                folder = os.path.join(hub, repo)
                wanted_revisions = repos.get(store, {}).get(repo)
                if wanted_revisions is None:
                    reason = moved(store, repo, repos) or "repository no longer in catalog"
                    for path in files_below(folder):
                        if path not in live:
                            add(path, reason)
                    continue
                for path in files_below(os.path.join(folder, "snapshots")):
                    if path in live or ".damaged-" in os.path.basename(path):
                        # Damaged copies of wanted files stay for inspection until their repository goes.
                        continue
                    revision = Path(path).relative_to(Path(folder) / "snapshots").parts[0]
                    add(
                        path,
                        "file no longer in catalog"
                        if revision in wanted_revisions
                        else f"superseded revision {revision[:12]}",
                    )
                blobs = os.path.join(folder, "blobs")
                for blob in os.listdir(blobs) if os.path.isdir(blobs) else []:
                    path = norm(os.path.join(blobs, blob))
                    if DIGEST.fullmatch(blob) and path not in live:
                        add(path, "blob no longer referenced")
            standalone = os.path.join(store, "files")
            for digest in sorted(os.listdir(standalone)) if os.path.isdir(standalone) else []:
                if not DIGEST.fullmatch(digest) or digest in digests.get(store, set()):
                    continue
                reason = moved(store, digest, digests) or "standalone file no longer in catalog"
                for path in files_below(os.path.join(standalone, digest)):
                    if path not in live:
                        add(path, reason)
        return plan, stores, managed, repos, areas

    def prune(self, dry_run=False):
        out = sys.stdout if dry_run else sys.stderr
        if not self.wanted:
            print("prune: refusing to prune: the catalog has no enabled entries", file=out, flush=True)
            return False
        plan, stores, managed, repos, areas = self.prune_plan()
        if not dry_run:
            atomic_json(self.state / "managed.json", {"repositories": sorted(managed)})
        holder = self.holders()
        verb = "would remove" if dry_run else "removed"
        removed, deferred, freed, failures = set(), 0, 0, 0
        for path, size, reason in plan:
            if not any(path == area or path.startswith(area + os.sep) for area in areas):
                raise AssertionError(f"Refusing to remove {path} outside managed storage")
            files = (
                [path]
                if not os.path.isdir(path) or os.path.islink(path)
                else [os.path.join(d, f) for d, _, names in os.walk(path) for f in names]
            )
            pids = {holder(os.stat(f)) for f in files if not os.path.islink(f) and os.path.isfile(f)} - {None}
            if pids:
                deferred += 1
                print(
                    f"prune: deferred {path} ({human(size)}): open by pid {', '.join(sorted(pids))}; retried next run",
                    file=out,
                    flush=True,
                )
                continue
            if not dry_run:
                try:
                    for root in self.mounted:
                        if path.startswith(norm(root) + os.sep):
                            self.verify(root)
                    if os.path.isdir(path) and not os.path.islink(path):
                        shutil.rmtree(path)
                    else:
                        os.unlink(path)
                except OSError as error:
                    failures += 1
                    print(f"prune: failed to remove {path}: {type(error).__name__}", file=out, flush=True)
                    continue
            removed.add(path)
            freed += size
            print(f"prune: {verb} {path} ({human(size)}, {size} bytes): {reason}", file=out, flush=True)
        if not dry_run:
            for path in sorted(removed, key=len, reverse=True):
                directory = os.path.dirname(path)
                while any(directory.startswith(area + os.sep) for area in areas):
                    try:
                        os.rmdir(directory)
                    except OSError:
                        break
                    directory = os.path.dirname(directory)
            if len(stores) == len({norm(p) for p in self.stores.values()}):
                gone = {
                    repo
                    for repo in managed
                    if not any(os.path.lexists(os.path.join(s, "huggingface", repo)) for s in stores)
                    and not any(repo in repos.get(s, {}) for s in stores)
                }
                atomic_json(self.state / "managed.json", {"repositories": sorted(managed - gone)})
            self.stamps = {k: v for k, v in self.stamps.items() if norm(k) not in removed}
            atomic_json(self.stamps_path, self.stamps)
        summary = "would free" if dry_run else "freed"
        print(
            f"prune: {len(removed)} paths {verb}, {summary} {human(freed)} ({freed} bytes); {deferred} deferred",
            file=out,
            flush=True,
        )
        return not failures


def prepare_reference(view, spec):
    from pyarrow.parquet import read_table

    audio_path = view / relative(spec["audio"])
    text_path = view / relative(spec["textFile"])
    if audio_path.is_file() and text_path.is_file():
        return
    rows = read_table(view / relative(spec["file"])).to_pylist()
    matching = [row for row in rows if row.get("name") == spec["speaker"]]
    if len(matching) != 1:
        raise ValueError("Expected exactly one reference speaker")
    row = matching[0]
    audio, text = row.get("audio", {}).get("bytes"), row.get("transcription")
    if not audio or not audio.startswith(b"RIFF") or not isinstance(text, str) or not text.strip():
        raise ValueError("Reference must contain embedded WAV and transcript")
    audio_path.write_bytes(audio)
    text_path.write_text(text, encoding="utf-8")


def fingerprint(catalog):
    return hashlib.sha256(json.dumps(catalog, sort_keys=True).encode()).hexdigest()


def load(catalog_path, retained_path):
    """Read the deployed catalog and retained entries; any damage stops sync and pruning."""
    catalog = json.loads(catalog_path.read_text())
    if not isinstance(catalog.get("entries"), dict) or not catalog["entries"]:
        raise ValueError("Catalog has no entries")
    if not retained_path.exists():
        print(f"{retained_path} is absent; pruning is disabled until it is deployed", file=sys.stderr, flush=True)
        return catalog, None
    retained = json.loads(retained_path.read_text())
    if not isinstance(retained.get("entries"), dict):
        raise ValueError("Retained entries are malformed")
    if not retained.get("generation") or retained["generation"] != catalog.get("generation"):
        print(
            f"{retained_path} is from another deployment than the catalog; pruning is disabled until both match",
            file=sys.stderr,
            flush=True,
        )
        return catalog, None
    return catalog, retained


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["sync", "request", "status", "validate", "prune", "split"])
    parser.add_argument("paths", nargs="*", type=Path, help="split: SOURCE OUTPUT-DIRECTORY")
    parser.add_argument(
        "--root", type=Path, default=Path(os.environ.get("MODEL_ROOT", Path.home() / ".local/share/models"))
    )
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--retained", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="prune: list what would go without removing it")
    args = parser.parse_args()
    catalog_path = args.catalog or args.root / "catalog.json"
    retained_path = args.retained or args.root / ".state/retained.json"
    if args.command == "split":
        source, output = args.paths
        consumer, retained = split(json.loads(source.read_text()))
        output.mkdir(parents=True)
        (output / "catalog.json").write_text(json.dumps(consumer, indent=2) + "\n")
        (output / "retained.json").write_text(json.dumps(retained, indent=2) + "\n")
        return 0
    if args.command == "request":
        with locked(args.root / ".state/request.lock"):
            (args.root / ".state/pending").touch()
        return 0
    if args.command == "status":
        if not (args.root / "readiness.json").exists():
            print("No readiness report yet. Host: systemctl --user start local-models-sync.service")
            return 1
        report = json.loads((args.root / "readiness.json").read_text())
        catalog = json.loads(catalog_path.read_text())
        current = report.get("catalogFingerprint") == fingerprint(catalog)
        if not current:
            print("Catalog changed since last sync; report below is from the previous deployment.")
        for alias, entry in catalog["entries"].items():
            item = report["entries"].get(alias, {})
            print(f"{alias:32} {item.get('status', 'pending'):20} {item.get('reason', '')}")
        print("Report:", args.root / "readiness.json")
        return 0 if current and report["complete"] else 1
    try:
        catalog, retained = load(catalog_path, retained_path)
        Sync(args.root, catalog, retained=retained, readonly=True)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(
            f"Catalog unreadable or invalid ({type(error).__name__}: {error}); nothing synchronized or pruned",
            file=sys.stderr,
        )
        return 2
    if args.command == "validate":
        return 0
    if args.command == "prune" and args.dry_run:
        if retained is None:
            print("Retained entries are not deployed; a real run would refuse to prune")
        return 0 if Sync(args.root, catalog, retained=retained, readonly=True).prune(dry_run=True) else 1
    with locked(args.root / ".state/sync.lock"):
        with locked(args.root / ".state/request.lock"):
            if args.command == "sync":
                (args.root / ".state/pending").unlink(missing_ok=True)
            try:
                catalog, retained = load(catalog_path, retained_path)
                sync = Sync(args.root, catalog, retained=retained, prune=retained is not None)
            except (OSError, ValueError, KeyError, TypeError) as error:
                print(
                    f"Catalog unreadable or invalid ({type(error).__name__}); nothing synchronized or pruned",
                    file=sys.stderr,
                )
                return 2
        if args.command == "prune":
            if retained is None:
                return 1
            return 0 if sync.prune() else 1
        # systemd.path rechecks pending after exit, including requests arriving at exit.
        return 0 if sync.reconcile() else 1


if __name__ == "__main__":
    sys.exit(main())
