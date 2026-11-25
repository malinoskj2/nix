#!/usr/bin/env python3
"""Host-only, pinned model reconciliation. No inference and no automatic pruning."""

import argparse
from contextlib import contextmanager
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


class Sync:
    def __init__(self, root, catalog, downloader=None):
        self.root, self.catalog = Path(root), catalog
        self.downloader = downloader or self.download
        self.order = validate(catalog)
        self.stores = {name: Path(path) for name, path in catalog.get("stores", {"root": str(self.root)}).items()}
        self.default_store = catalog.get("defaultStore", "root")
        self.state = self.root / ".state"
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
            if not self.valid(source, file):
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
                if shutil.disk_usage(store).free < file["size"] + 2 * 1024**3:
                    raise OSError("Insufficient space to safely import project weights")
                temporary = blob.with_suffix(".importing")
                subprocess.run(["cp", "--reflink=auto", "--", str(source.resolve()), str(temporary)], check=True)
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
        destination = self.destination(file, store)
        if self.valid(destination, file):
            return destination
        if file.get("storePath"):
            raise FileNotFoundError("Packaged asset missing")
        if self.import_file(file, destination, store):
            return destination
        if shutil.disk_usage(store).free < file["size"] + 2 * 1024**3:
            raise OSError("Insufficient free disk space including download headroom")
        # Preserve a damaged cache blob for inspection; let Hub fetch only this file.
        if destination.exists():
            blob = destination.resolve()
            if blob.is_relative_to(store):
                blob.rename(blob.with_name(blob.name + f".damaged-{time.time_ns()}"))
            destination.unlink(missing_ok=True)
        downloaded = self.downloader(file, store)
        if not self.valid(downloaded, file):
            raise ValueError("Downloaded file failed size/hash verification")
        if downloaded != destination:
            link(downloaded, destination)
        return destination

    def reconcile(self):
        report = {}
        enabled = {a for a, e in self.catalog["entries"].items() if e["enabled"]}

        def enable_dependencies(alias):
            for dep in self.catalog["entries"][alias].get("dependencies", []):
                if dep not in enabled:
                    enabled.add(dep)
                    enable_dependencies(dep)

        for alias in list(enabled):
            enable_dependencies(alias)
        for alias in self.order:
            entry = self.catalog["entries"][alias]
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
            if alias not in enabled:
                item["status"] = "historical-disabled"
                continue
            if entry.get("unresolved"):
                item.update(status="unresolved", reason=entry["unresolved"])
                continue
            if any(not f.get("storePath") for f in entry["files"]) and not available(store):
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
        complete = all(v["status"] in ["ready", "historical-disabled"] for v in report.values())
        failed = []
        for alias, item in report.items():
            if item["status"] in ["ready", "historical-disabled"]:
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
        return not failed


def available(store):
    try:
        store.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    return os.access(store, os.W_OK)


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["sync", "request", "status", "validate"])
    parser.add_argument(
        "--root", type=Path, default=Path(os.environ.get("MODEL_ROOT", Path.home() / ".local/share/models"))
    )
    parser.add_argument("--catalog", type=Path)
    args = parser.parse_args()
    catalog_path = args.catalog or args.root / "catalog.json"
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
    catalog = json.loads(catalog_path.read_text())
    validate(catalog)
    if args.command == "validate":
        return 0
    with locked(args.root / ".state/sync.lock"):
        with locked(args.root / ".state/request.lock"):
            (args.root / ".state/pending").unlink(missing_ok=True)
            catalog = json.loads(catalog_path.read_text())
        # systemd.path rechecks pending after exit, including requests arriving at exit.
        return 0 if Sync(args.root, catalog).reconcile() else 1


if __name__ == "__main__":
    sys.exit(main())
