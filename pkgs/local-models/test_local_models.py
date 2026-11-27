import copy
import hashlib
import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from local_models import Sync, locked, main, validate, prepare_reference, split


def file_spec(name="model.bin", content=b"model", revision="a" * 40, repository="fixture/model"):
    return {
        "repository": repository,
        "revision": revision,
        "path": name,
        "target": name,
        "size": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
    }


def entry(files=None, **kwargs):
    return {
        "enabled": True,
        "kind": "checkpoint",
        "files": files or [],
        "dependencies": [],
        "compatibility": "unverified",
        **kwargs,
    }


def hold_lock(path, ready, release):
    with locked(Path(path)):
        ready.set()
        release.wait(10)


class Synchronization(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.catalog = {"entries": {"base": entry([file_spec()])}}
        self.calls = []

    def downloader(self, file, store=None):
        self.calls.append(file["path"])
        target = Sync(self.root, self.catalog).destination(file, store)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"model")
        return target

    def sync(self, catalog=None, downloader=None):
        return Sync(self.root, catalog or self.catalog, downloader or self.downloader).reconcile()

    def report(self):
        return json.loads((self.root / "readiness.json").read_text())["entries"]

    def test_second_sync_is_offline_and_alias_changes_reuse_files(self):
        self.assertTrue(self.sync())
        self.assertEqual(self.calls, ["model.bin"])
        with patch("socket.socket", side_effect=AssertionError("Network forbidden")):
            self.assertTrue(self.sync(downloader=lambda *_: self.fail("Download attempted")))
            renamed = copy.deepcopy(self.catalog)
            renamed["entries"]["friendly-name"] = renamed["entries"].pop("base")
            self.assertTrue(self.sync(renamed, lambda *_: self.fail("Download attempted")))
        self.assertEqual((self.root / "by-name/friendly-name/model.bin").read_bytes(), b"model")
        self.assertFalse(self.report()["friendly-name"]["consumerReady"])

    def test_one_missing_or_damaged_file_repairs_only_that_file(self):
        self.catalog["entries"]["base"]["files"].append(file_spec("second.bin"))
        self.sync()
        path = Sync(self.root, self.catalog).destination(file_spec())
        path.unlink()
        self.calls.clear()
        self.sync()
        self.assertEqual(self.calls, ["model.bin"])
        path.write_bytes(b"wrong")
        self.calls.clear()
        self.sync()
        self.assertEqual(self.calls, ["model.bin"])
        self.assertTrue(list(path.parent.glob("*.damaged-*")))

    def test_failed_revision_preserves_working_alias(self):
        self.sync()
        old = (self.root / "by-name/base").resolve()
        updated = copy.deepcopy(self.catalog)
        updated["entries"]["base"]["files"][0]["revision"] = "b" * 40

        def fail(_):
            raise ConnectionError("offline")

        self.assertFalse(self.sync(updated, fail))
        self.assertEqual((self.root / "by-name/base").resolve(), old)
        self.assertEqual(self.report()["base"]["status"], "missing")

    def test_import_verifies_and_preserves_original_and_reuses(self):
        source = self.root / "project/model"
        source.parent.mkdir()
        source.write_bytes(b"model")
        self.catalog["entries"]["base"]["files"][0]["imports"] = [str(source)]
        self.assertTrue(self.sync(downloader=lambda *_: self.fail("Download attempted")))
        imported = (self.root / "by-name/base/model.bin").resolve()
        self.assertNotEqual(source.stat().st_ino, imported.stat().st_ino)
        source.write_bytes(b"other")
        self.assertEqual(imported.read_bytes(), b"model")
        self.assertTrue(self.sync(downloader=lambda *_: self.fail("Download attempted")))

    def test_shared_blob_is_reused_across_revisions_without_copy(self):
        spec = self.catalog["entries"]["base"]["files"][0]
        blob = self.root / "huggingface/models--fixture--model/blobs" / spec["sha256"]
        blob.parent.mkdir(parents=True)
        blob.write_bytes(b"model")
        self.assertTrue(self.sync(downloader=lambda *_: self.fail("Network attempted")))
        self.assertEqual((self.root / "by-name/base/model.bin").resolve(), blob)
        spec["revision"] = "b" * 40
        self.assertTrue(self.sync(downloader=lambda *_: self.fail("Network attempted")))
        self.assertEqual((self.root / "by-name/base/model.bin").resolve(), blob)
        self.assertFalse((self.root / "files").exists())

    def test_corrupt_import_is_not_published(self):
        bad = self.root / "bad"
        bad.write_bytes(b"wrong")
        self.catalog["entries"]["base"]["files"][0]["imports"] = [str(bad)]
        self.sync()
        self.assertEqual(self.calls, ["model.bin"])
        self.assertEqual(bad.read_bytes(), b"wrong")

    def test_public_progress_survives_gated_failure_and_no_secret_logged(self):
        self.catalog["entries"]["gated"] = entry([file_spec("gated")], gated=True)

        def download(file, store):
            if file["path"] == "gated":
                raise PermissionError("secret-token-must-not-be-logged")
            return self.downloader(file, store)

        with patch("sys.stderr") as stderr:
            self.assertFalse(self.sync(downloader=download))
            self.assertNotIn("secret-token", str(stderr.mock_calls))
        self.assertEqual(self.report()["base"]["status"], "ready")
        self.assertEqual(self.report()["gated"]["status"], "blocked")

    def test_missing_invalid_and_empty_credentials_allow_public_downloads(self):
        credentials = self.root / "credentials"
        credentials.mkdir()
        for token in ["", "unconfigured", "HF_TOKEN=not-raw"]:
            (credentials / "hf-token").write_text(token)
            with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(credentials), "HF_TOKEN": "inherited"}):
                sync = Sync(self.root, self.catalog, self.downloader)
                self.assertIs(sync.token, False)
                self.assertNotIn("HF_TOKEN", os.environ)
                self.assertTrue(sync.reconcile())

    def test_adapter_dependencies_and_compatibility_are_separate(self):
        self.catalog["entries"]["adapter"] = entry(
            [file_spec("adapter_config.json")],
            kind="adapter",
            base="base",
            dependencies=["base"],
            loader="PEFT",
            compatibility="unverified",
        )
        self.assertTrue(self.sync())
        self.assertFalse(self.report()["adapter"]["consumerReady"])
        self.catalog["entries"]["adapter"]["compatibility"] = "validated"
        self.assertTrue(self.sync())
        self.assertFalse(self.report()["adapter"]["consumerReady"])
        self.catalog["entries"]["base"]["unresolved"] = "Unknown architecture"
        self.assertTrue(self.sync())
        self.assertEqual(self.report()["adapter"]["status"], "unresolved")

    def test_missing_base_cycles_and_bad_paths_rejected_before_download(self):
        examples = [
            {"adapter": entry(kind="adapter", dependencies=["absent"], base="absent", loader="PEFT")},
            {"a": entry(dependencies=["b"]), "b": entry(dependencies=["a"])},
            {"adapter": entry(kind="adapter")},
            {"a": entry([{**file_spec(), "target": "../escape"}])},
            {"a": entry([{**file_spec(), "revision": "main"}])},
        ]
        for entries in examples:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                validate({"entries": entries})

    def test_incompatible_adapter_base_revision_is_rejected(self):
        self.catalog["entries"]["adapter"] = entry(
            kind="adapter",
            base="base",
            dependencies=["base"],
            loader="PEFT",
            baseSources=[{"repository": "fixture/model", "revision": "b" * 40}],
        )
        with self.assertRaisesRegex(ValueError, "base revision"):
            validate(self.catalog)

    def test_merged_checkpoint_does_not_require_adapter_or_base(self):
        self.catalog["entries"]["base"]["kind"] = "merged-checkpoint"
        self.assertTrue(self.sync())
        self.assertEqual(self.report()["base"]["kind"], "merged-checkpoint")

    def test_dependencies_are_enabled_and_views_resolve(self):
        self.catalog["entries"]["base"]["enabled"] = False
        self.catalog["entries"]["pipeline"] = entry(kind="pipeline", dependencies=["base"], views={"component": "base"})
        self.assertTrue(self.sync())
        self.assertEqual((self.root / "by-name/pipeline/component/model.bin").read_bytes(), b"model")

    def test_incomplete_pipeline_update_preserves_old_dependency_views(self):
        self.catalog["entries"]["other"] = entry([file_spec("other.bin")])
        self.catalog["entries"]["pipeline"] = entry(
            kind="pipeline", dependencies=["base", "other"], views={"base": "base", "other": "other"}
        )
        self.sync()
        old_base = (self.root / "by-name/pipeline/base").resolve()
        updated = copy.deepcopy(self.catalog)
        updated["entries"]["base"]["files"][0]["revision"] = "b" * 40
        updated["entries"]["other"]["unresolved"] = "New source not verified"
        self.assertTrue(self.sync(updated))
        self.assertNotEqual((self.root / "by-name/base").resolve(), old_base)
        self.assertEqual((self.root / "by-name/pipeline/base").resolve(), old_base)
        self.assertEqual(self.report()["pipeline"]["status"], "unresolved")

    def test_adapter_with_missing_configuration_is_not_published(self):
        self.catalog["entries"]["adapter"] = entry(
            [file_spec("adapter_model.safetensors"), file_spec("adapter_config.json")],
            kind="adapter",
            base="base",
            dependencies=["base"],
            loader="PEFT",
        )

        def download(file, store):
            if file["path"] == "adapter_config.json":
                raise FileNotFoundError("configuration absent")
            return self.downloader(file, store)

        self.assertFalse(self.sync(downloader=download))
        self.assertFalse((self.root / "by-name/adapter").exists())
        self.assertFalse(self.report()["adapter"]["consumerReady"])

    def test_disabled_and_unresolved_remain_distinct(self):
        self.catalog["entries"]["base"]["enabled"] = False
        self.catalog["entries"]["unknown"] = entry(unresolved="No provenance")
        self.assertTrue(self.sync())
        self.assertEqual(self.calls, [])
        self.assertNotIn("base", self.report())
        self.assertEqual(self.report()["unknown"]["status"], "unresolved")

    def test_declared_unresolved_entries_report_but_do_not_fail_sync(self):
        self.catalog["entries"]["dino"] = entry(unresolved="Checksum not verified")
        self.catalog["entries"]["pipeline"] = entry(kind="pipeline", dependencies=["base", "dino"])
        with patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertTrue(self.sync())
        self.assertIn("dino: unresolved: Checksum not verified", stderr.getvalue())
        self.assertIn("pipeline: unresolved: Required dependency is not ready", stderr.getvalue())
        self.assertFalse(json.loads((self.root / "readiness.json").read_text())["complete"])

    def test_failed_sync_names_the_failing_entries(self):
        def download(file, store):
            raise FileNotFoundError("absent")

        with patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertFalse(self.sync(downloader=download))
        self.assertIn("base: missing: Required files missing", stderr.getvalue())
        self.assertIn("Sync failed for 1 entries: base", stderr.getvalue())

    def test_git_blob_hash_verification(self):
        f = file_spec()
        f.pop("sha256")
        f["gitSha1"] = hashlib.sha1(b"blob 5\0model").hexdigest()
        self.catalog["entries"]["base"]["files"] = [f]
        self.assertTrue(self.sync())

    def test_interrupted_transfer_is_retried_without_losing_partial(self):
        partial = self.root / "download.incomplete"

        def interrupted(*_):
            partial.write_bytes(b"mo")
            raise ConnectionError("interrupted")

        self.assertFalse(self.sync(downloader=interrupted))
        self.assertEqual(partial.read_bytes(), b"mo")
        self.assertTrue(self.sync())
        self.assertEqual(partial.read_bytes(), b"mo")

    def test_requests_survive_transfer_and_request_at_exit(self):
        catalog = self.root / "catalog.json"
        catalog.write_text(json.dumps(self.catalog))

        def request():
            with patch.object(sys, "argv", ["local-models", "request", "--root", str(self.root)]):
                main()

        request()

        def during_download(file, store):
            updated = copy.deepcopy(self.catalog)
            updated["entries"]["new"] = entry([file_spec("new.bin")])
            catalog.write_text(json.dumps(updated))
            request()
            return self.downloader(file, store)

        with (
            patch.object(sys, "argv", ["local-models", "sync", "--root", str(self.root)]),
            patch.object(Sync, "download", side_effect=during_download),
        ):
            self.assertEqual(main(), 0)
        self.assertTrue((self.root / ".state/pending").exists())
        self.assertNotIn("new", self.report())
        with (
            patch.object(sys, "argv", ["local-models", "sync", "--root", str(self.root)]),
            patch.object(Sync, "download", side_effect=self.downloader),
        ):
            self.assertEqual(main(), 0)
        self.assertEqual(self.report()["new"]["status"], "ready")
        self.assertFalse((self.root / ".state/pending").exists())
        request()  # systemd.path checks this marker again after service exit.
        self.assertTrue((self.root / ".state/pending").exists())

    def test_sync_lock_serializes_processes(self):
        context = multiprocessing.get_context("spawn")
        ready, release = context.Event(), context.Event()
        path = self.root / "lock"
        process = context.Process(target=hold_lock, args=(str(path), ready, release))
        process.start()
        self.addCleanup(lambda: process.kill() if process.is_alive() else None)
        self.assertTrue(ready.wait(5))
        code = 'from local_models import locked; from pathlib import Path; import sys;\nwith locked(Path(sys.argv[1])): print("acquired")'
        second = subprocess.Popen(
            [sys.executable, "-c", code, str(path)], stdout=subprocess.PIPE, cwd=Path(__file__).parent
        )
        self.addCleanup(lambda: second.kill() if second.poll() is None else None)
        time.sleep(0.1)
        self.assertIsNone(second.poll())
        release.set()
        process.join(5)
        output, _ = second.communicate(timeout=5)
        self.assertEqual(output.strip(), b"acquired")


class Stores(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "external"
        self.install = self.base / "install"
        self.catalog = {
            "stores": {"external": str(self.root), "install": str(self.install)},
            "defaultStore": "external",
            "entries": {
                "old": entry([file_spec("old.bin")]),
                "voice": entry([file_spec("voice.bin")], store="install"),
            },
        }

    def downloader(self, file, store):
        target = Sync(self.root, self.catalog).destination(file, store)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"model")
        return target

    def test_entries_sync_into_their_store_behind_one_root(self):
        self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        report = json.loads((self.root / "readiness.json").read_text())["entries"]
        self.assertEqual(report["old"]["store"], "external")
        self.assertEqual(report["voice"]["store"], "install")
        self.assertTrue(
            (self.root / "by-name/old/old.bin").resolve().is_relative_to(self.root / "huggingface"),
        )
        voice = (self.root / "by-name/voice/voice.bin").resolve()
        self.assertTrue(voice.is_relative_to(self.install / "huggingface"))
        self.assertEqual((self.root / "by-name/voice/voice.bin").read_bytes(), b"model")
        self.assertFalse((self.install / "by-name").exists())
        self.assertFalse(
            (self.root / "huggingface/models--fixture--model/snapshots/" / ("a" * 40) / "voice.bin").exists()
        )
        with patch("socket.socket", side_effect=AssertionError("Network forbidden")):
            self.assertTrue(Sync(self.root, self.catalog, lambda *_: self.fail("Download attempted")).reconcile())

    def test_moving_an_entry_copies_into_the_new_store(self):
        self.catalog["entries"]["voice"].pop("store")
        self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        self.catalog["entries"]["voice"]["store"] = "install"
        self.assertTrue(Sync(self.root, self.catalog, lambda *_: self.fail("Download attempted")).reconcile())
        voice = (self.root / "by-name/voice/voice.bin").resolve()
        self.assertTrue(voice.is_relative_to(self.install))
        self.assertEqual(voice.read_bytes(), b"model")
        old = self.root / "huggingface/models--fixture--model/snapshots/" / ("a" * 40)
        self.assertFalse((old / "voice.bin").exists(), "the published move prunes the old store's copy")
        self.assertTrue((old / "old.bin").is_file())

    def test_unavailable_store_is_not_pruned(self):
        self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        voice = self.install / "huggingface/models--fixture--model/snapshots" / ("a" * 40) / "voice.bin"
        moved = self.base / "unplugged"
        self.install.rename(moved)
        self.catalog["entries"].pop("voice")
        self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        moved.rename(self.install)
        self.assertTrue(voice.is_file())

    def test_unavailable_store_reports_missing_without_touching_others(self):
        blocker = self.base / "absent"
        blocker.write_text("")
        self.catalog["stores"]["install"] = str(blocker / "store")
        self.assertFalse(Sync(self.root, self.catalog, self.downloader).reconcile())
        report = json.loads((self.root / "readiness.json").read_text())["entries"]
        self.assertEqual(report["old"]["status"], "ready")
        self.assertEqual(report["voice"]["status"], "missing")
        self.assertIn("unavailable", report["voice"]["reason"])

    def test_unmounted_network_store_reports_missing_and_creates_nothing(self):
        self.install.mkdir()
        self.catalog["mountedStores"] = ["install"]
        with patch("os.path.ismount", return_value=False):
            self.assertFalse(Sync(self.root, self.catalog, self.downloader).reconcile())
        report = json.loads((self.root / "readiness.json").read_text())["entries"]
        self.assertEqual(report["old"]["status"], "ready")
        self.assertEqual(report["voice"]["status"], "missing")
        self.assertIn("unavailable", report["voice"]["reason"])
        self.assertEqual(list(self.install.iterdir()), [])
        self.assertFalse((self.root / "by-name/voice").exists())

    def test_absent_network_mount_point_is_never_created(self):
        self.catalog["mountedStores"] = ["install"]
        self.assertFalse(Sync(self.root, self.catalog, self.downloader).reconcile())
        self.assertFalse(self.install.exists())

    def test_mounted_network_store_syncs(self):
        self.install.mkdir()
        self.catalog["mountedStores"] = ["install"]
        real = os.path.ismount
        with patch("os.path.ismount", side_effect=lambda p: Path(p) == self.install or real(p)):
            self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
            self.assertTrue((self.root / "by-name/voice/voice.bin").resolve().is_relative_to(self.install))
            self.catalog["entries"].pop("voice")
            self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        self.assertFalse(any((self.install / "huggingface").rglob("voice.bin")))

    def test_unmounted_network_store_is_not_pruned(self):
        self.install.mkdir()
        self.catalog["mountedStores"] = ["install"]
        real = os.path.ismount
        with patch("os.path.ismount", side_effect=lambda p: Path(p) == self.install or real(p)):
            self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        voice = self.install / "huggingface/models--fixture--model/snapshots" / ("a" * 40) / "voice.bin"
        self.catalog["entries"].pop("voice")
        with patch("os.path.ismount", return_value=False):
            self.assertTrue(Sync(self.root, self.catalog, self.downloader).reconcile())
        self.assertTrue(voice.is_file())

    def test_store_reserve_keeps_free_space(self):
        self.catalog["storeReserves"] = {"install": 1 << 60}
        self.assertFalse(Sync(self.root, self.catalog, self.downloader).reconcile())
        report = json.loads((self.root / "readiness.json").read_text())["entries"]
        self.assertEqual(report["old"]["status"], "ready")
        self.assertEqual(report["voice"]["status"], "missing")
        self.assertFalse(any(self.install.rglob("voice.bin")))

    def test_unknown_or_invalid_stores_rejected(self):
        bad = copy.deepcopy(self.catalog)
        bad["mountedStores"] = ["nowhere"]
        self.assertRaises(ValueError, validate, bad)
        bad = copy.deepcopy(self.catalog)
        bad["storeReserves"] = {"install": -1}
        self.assertRaises(ValueError, validate, bad)
        bad = copy.deepcopy(self.catalog)
        bad["entries"]["voice"]["store"] = "nowhere"
        self.assertRaises(ValueError, validate, bad)
        bad = copy.deepcopy(self.catalog)
        bad["defaultStore"] = "nowhere"
        self.assertRaises(ValueError, validate, bad)
        bad = copy.deepcopy(self.catalog)
        bad["stores"]["install"] = "relative/path"
        self.assertRaises(ValueError, validate, bad)


class Pruning(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.contents = {}
        self.calls = []
        self.catalog = {
            "entries": {
                "base": entry([self.spec("model.bin", b"model")]),
                "other": entry([self.spec("other.bin", b"other-weights", repository="fixture/other")]),
            }
        }

    def spec(self, name, content, **kwargs):
        self.contents[hashlib.sha256(content).hexdigest()] = content
        return file_spec(name, content, **kwargs)

    def hub(self, file, store):
        """Lay files out as huggingface_hub does: a content-addressed blob and a relative snapshot link."""
        self.calls.append(file["path"])
        sync = Sync(self.root, self.catalog)
        destination = sync.destination(file, store)
        blob = destination.parents[len(Path(file["path"]).parts) + 1] / "blobs" / file["sha256"]
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(self.contents[file["sha256"]])
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(os.path.relpath(blob, destination.parent))
        return destination

    def offline(self, *_):
        raise ConnectionError("offline")

    def sync(self, catalog=None, downloader=None):
        with patch("sys.stderr", new_callable=io.StringIO) as stderr:
            result = Sync(self.root, catalog or self.catalog, downloader or self.hub).reconcile()
        self.log = stderr.getvalue()
        return result

    def repo(self, name="other"):
        return self.root / "huggingface" / f"models--fixture--{name}"

    def report(self):
        return json.loads((self.root / "readiness.json").read_text())["entries"]

    def deploy(self, catalog):
        consumer, retained = split(catalog)
        (self.root / "catalog.json").write_text(json.dumps(consumer))
        (self.root / ".state").mkdir(exist_ok=True)
        (self.root / ".state/retained.json").write_text(json.dumps(retained))

    def run_main(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            patch.object(sys, "argv", ["local-models", *arguments, "--root", str(self.root)]),
            patch.object(Sync, "download", side_effect=self.hub),
            patch("sys.stdout", stdout),
            patch("sys.stderr", stderr),
        ):
            code = main()
        return code, stdout.getvalue() + stderr.getvalue()

    def test_removed_entry_files_go(self):
        self.assertTrue(self.sync())
        blob = (self.root / "by-name/other/other.bin").resolve()
        self.catalog["entries"].pop("other")
        self.assertTrue(self.sync(downloader=self.offline))
        self.assertFalse(self.repo().exists())
        self.assertFalse(os.path.lexists(self.root / "by-name/other"))
        self.assertFalse((self.root / "views/other").exists())
        self.assertEqual((self.root / "by-name/base/model.bin").read_bytes(), b"model")
        self.assertIn(f"prune: removed {blob} (13 B, 13 bytes): repository no longer in catalog", self.log)
        self.assertIn("alias no longer in catalog", self.log)

    def test_disabled_entry_stays_on_disk_invisibly_and_reenables_instantly(self):
        self.assertTrue(self.sync())
        self.catalog["entries"]["other"]["enabled"] = False
        consumer, retained = split(self.catalog)
        self.assertNotIn("other", consumer["entries"])
        self.assertIn("other", retained["entries"])
        self.deploy(self.catalog)
        self.assertEqual(self.run_main("sync")[0], 0)
        self.assertNotIn("other", self.report())
        self.assertTrue(json.loads((self.root / "readiness.json").read_text())["complete"])
        self.assertFalse(os.path.lexists(self.root / "by-name/other"))
        self.assertTrue((self.repo() / "blobs" / file_spec("x", b"other-weights")["sha256"]).is_file())
        self.catalog["entries"]["other"]["enabled"] = True
        self.calls.clear()
        with patch("socket.socket", side_effect=AssertionError("Network forbidden")):
            self.assertTrue(self.sync(downloader=lambda *_: self.fail("Download attempted")))
        self.assertEqual(self.report()["other"]["status"], "ready")
        self.assertEqual((self.root / "by-name/other/other.bin").read_bytes(), b"other-weights")

    def test_disabled_dependency_of_an_enabled_entry_stays_visible(self):
        self.catalog["entries"]["base"]["enabled"] = False
        self.catalog["entries"]["pipeline"] = entry(kind="pipeline", dependencies=["base"], views={"b": "base"})
        consumer, retained = split(self.catalog)
        self.assertIn("base", consumer["entries"])
        self.assertNotIn("other", retained["entries"])

    def test_old_revision_goes_only_after_the_new_one_publishes(self):
        self.assertTrue(self.sync())
        old = self.repo("model") / "snapshots" / ("a" * 40) / "model.bin"
        old_blob = old.resolve()
        updated = copy.deepcopy(self.catalog)
        updated["entries"]["base"]["files"] = [self.spec("model.bin", b"model-v2", revision="b" * 40)]
        partial = self.repo("model") / "blobs" / (updated["entries"]["base"]["files"][0]["sha256"] + ".incomplete")

        def interrupted(*_):
            partial.write_bytes(b"mod")
            raise ConnectionError("interrupted")

        self.assertFalse(self.sync(updated, interrupted))
        self.assertTrue(old.is_file() and old_blob.is_file())
        self.assertEqual((self.root / "by-name/base/model.bin").read_bytes(), b"model")
        self.assertTrue(partial.exists())
        self.assertNotIn("superseded", self.log)
        partial.unlink()
        self.catalog = updated
        self.assertTrue(self.sync(updated))
        self.assertEqual((self.root / "by-name/base/model.bin").read_bytes(), b"model-v2")
        self.assertFalse(os.path.lexists(old))
        self.assertFalse(old_blob.exists())
        self.assertIn(f"superseded revision {'a' * 12}", self.log)
        self.assertIn("blob no longer referenced", self.log)
        self.assertEqual(len(list((self.root / "views/base").iterdir())), 1)

    def test_blob_shared_with_a_wanted_revision_survives(self):
        self.catalog["entries"]["pinned"] = entry([self.spec("model.bin", b"model", revision="c" * 40)])
        self.assertTrue(self.sync())
        shared = (self.root / "by-name/base/model.bin").resolve()
        self.assertEqual((self.root / "by-name/pinned/model.bin").resolve(), shared)
        self.catalog["entries"].pop("base")
        self.assertTrue(self.sync(downloader=self.offline))
        self.assertFalse(os.path.lexists(self.repo("model") / "snapshots" / ("a" * 40)))
        self.assertTrue(shared.is_file())
        self.assertEqual((self.root / "by-name/pinned/model.bin").read_bytes(), b"model")

    def test_open_file_is_deferred_to_the_next_run(self):
        self.assertTrue(self.sync())
        blob = (self.root / "by-name/other/other.bin").resolve()
        self.catalog["entries"].pop("other")
        with blob.open("rb"):
            self.assertTrue(self.sync(downloader=self.offline))
            self.assertTrue(blob.is_file())
            self.assertIn(f"prune: deferred {blob}", self.log)
            self.assertIn(f"open by pid {os.getpid()}", self.log)
        self.assertTrue(self.sync(downloader=self.offline))
        self.assertFalse(blob.exists())
        self.assertFalse(self.repo().exists())

    def test_mapped_file_is_deferred(self):
        import mmap

        self.assertTrue(self.sync())
        blob = (self.root / "by-name/other/other.bin").resolve()
        self.catalog["entries"].pop("other")
        with blob.open("rb") as handle:
            mapping = mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            self.assertTrue(self.sync(downloader=self.offline))
            self.assertTrue(blob.is_file())
        finally:
            mapping.close()

    def test_broken_or_partial_catalog_deletes_nothing(self):
        self.deploy(self.catalog)
        self.assertEqual(self.run_main("sync")[0], 0)
        files = sorted(str(p) for p in self.root.rglob("*") if "/.state" not in str(p) and p.name != "readiness.json")
        text = (self.root / "catalog.json").read_text()
        updated = copy.deepcopy(self.catalog)
        updated["entries"].pop("other")
        consumer, _ = split(updated)
        for damaged in [text[: len(text) // 2], "", json.dumps({"entries": {}}), json.dumps({"schemaVersion": 1})]:
            with self.subTest(catalog=damaged[:30]):
                (self.root / "catalog.json").write_text(damaged)
                code, output = self.run_main("sync")
                self.assertEqual(code, 2)
                self.assertIn("nothing synchronized or pruned", output)
        (self.root / "catalog.json").write_text(json.dumps(consumer))
        (self.root / ".state/retained.json").write_text("{")
        self.assertEqual(self.run_main("sync")[0], 2)
        (self.root / ".state/retained.json").unlink()
        code, output = self.run_main("sync")
        self.assertIn("pruning is disabled", output)
        self.assertFalse(any("prune: removed" in line for line in output.splitlines()))
        after = sorted(str(p) for p in self.root.rglob("*") if "/.state" not in str(p) and p.name != "readiness.json")
        self.assertEqual(after, files)

    def test_catalog_and_retained_from_different_deployments_prune_nothing(self):
        self.deploy(self.catalog)
        self.assertEqual(self.run_main("sync")[0], 0)
        blob = (self.root / "by-name/other/other.bin").resolve()
        disabled = copy.deepcopy(self.catalog)
        disabled["entries"]["other"]["enabled"] = False
        consumer, retained = split(disabled)
        # Activation has linked the new catalog but not yet its retained entries.
        (self.root / "catalog.json").write_text(json.dumps(consumer))
        code, output = self.run_main("sync")
        self.assertEqual(code, 0)
        self.assertIn("pruning is disabled until both match", output)
        self.assertTrue(blob.is_file())
        self.assertTrue(os.path.lexists(self.root / "by-name/other"))
        (self.root / ".state/retained.json").write_text(json.dumps({**retained, "generation": None}))
        self.assertIn("pruning is disabled", self.run_main("sync")[1])
        self.assertTrue(blob.is_file())
        (self.root / ".state/retained.json").write_text(json.dumps(retained))
        self.assertEqual(self.run_main("sync")[0], 0)
        self.assertTrue(blob.is_file())
        self.assertFalse(os.path.lexists(self.root / "by-name/other"))

    def test_dry_run_lists_without_removing(self):
        self.deploy(self.catalog)
        self.assertEqual(self.run_main("sync")[0], 0)
        updated = copy.deepcopy(self.catalog)
        updated["entries"].pop("other")
        self.deploy(updated)
        before = sorted(self.root.rglob("*"))
        code, output = self.run_main("prune", "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("would remove", output)
        self.assertIn("would free 13 B (13 bytes)", output)
        self.assertEqual(sorted(self.root.rglob("*")), before)
        code, output = self.run_main("prune")
        self.assertEqual(code, 0)
        self.assertFalse(self.repo().exists())

    def test_unmanaged_cache_folders_and_files_outside_stores_are_untouched(self):
        foreign = self.root / "huggingface/models--someone--else/snapshots" / ("d" * 40) / "weights.bin"
        foreign.parent.mkdir(parents=True)
        foreign.write_bytes(b"theirs")
        outside = self.root / "project/model.bin"
        outside.parent.mkdir()
        outside.write_bytes(b"model")
        self.assertTrue(self.sync())
        self.catalog["entries"].pop("other")
        self.catalog["entries"].pop("base")
        self.catalog["entries"]["kept"] = entry([self.spec("k.bin", b"k", repository="fixture/kept")])
        self.assertTrue(self.sync())
        self.assertTrue(foreign.is_file() and outside.is_file())
        self.assertFalse(self.repo("model").exists())

    def test_removed_standalone_file_goes(self):
        content = b"standalone"
        standalone = {
            "url": "https://example.invalid/file.bin",
            "path": "file.bin",
            "target": "file.bin",
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }
        self.catalog["entries"]["plain"] = entry([standalone])

        def download(file, store):
            if file.get("url"):
                target = Sync(self.root, self.catalog).destination(file, store)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                return target
            return self.hub(file, store)

        self.assertTrue(self.sync(downloader=download))
        self.catalog["entries"].pop("plain")
        self.assertTrue(self.sync(downloader=self.offline))
        self.assertFalse((self.root / "files" / standalone["sha256"]).exists())
        self.assertIn("standalone file no longer in catalog", self.log)


class HubIntegration(unittest.TestCase):
    def test_real_hub_resume_offline_reuse_and_selective_repair(self):
        requests = []
        contents = {"first.bin": b"model-one", "second.bin": b"model-two"}

        class Handler(BaseHTTPRequestHandler):
            def do_HEAD(self):
                self.respond(False)

            def do_GET(self):
                self.respond(True)

            def respond(self, body):
                name = self.path.rsplit("/", 1)[-1]
                content = contents[name]
                offset = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
                requests.append((self.command, name, offset, self.headers.get("Authorization")))
                self.send_response(206 if offset else 200)
                self.send_header("Content-Length", str(len(content) - offset))
                self.send_header("ETag", hashlib.sha256(content).hexdigest())
                self.send_header("X-Repo-Commit", "a" * 40)
                if offset:
                    self.send_header("Content-Range", f"bytes {offset}-{len(content) - 1}/{len(content)}")
                self.end_headers()
                if body:
                    self.wfile.write(content[offset:])

            def log_message(self, *_):
                pass

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = {"entries": {"fixture": entry([file_spec(name, content) for name, content in contents.items()])}}
            (root / "catalog.json").write_text(json.dumps(catalog))
            partial = (
                root
                / "huggingface/models--fixture--model/blobs"
                / (hashlib.sha256(contents["first.bin"]).hexdigest() + ".incomplete")
            )
            partial.parent.mkdir(parents=True)
            partial.write_bytes(b"mod")
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                environment = {
                    **os.environ,
                    "HF_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
                    "HF_HUB_DISABLE_XET": "1",
                    "HF_HUB_DISABLE_TELEMETRY": "1",
                }
                import certifi

                environment["SSL_CERT_FILE"] = certifi.where()
                environment.pop("CREDENTIALS_DIRECTORY", None)
                command = [
                    sys.executable,
                    "-B",
                    str(Path(__file__).with_name("local_models.py")),
                    "sync",
                    "--root",
                    str(root),
                ]
                result = subprocess.run(command, env=environment, capture_output=True, text=True)
                if result.returncode:
                    diagnostic = subprocess.run(
                        [
                            sys.executable,
                            "-c",
                            "import json,sys; from pathlib import Path; from local_models import Sync; root=Path(sys.argv[1]); catalog=json.loads((root/'catalog.json').read_text()); s=Sync(root,catalog); s.obtain(catalog['entries']['fixture']['files'][0], s.store({}))",
                            str(root),
                        ],
                        cwd=Path(__file__).parent,
                        env=environment,
                        capture_output=True,
                        text=True,
                    )
                    self.fail(result.stderr + diagnostic.stderr)
                self.assertIn(("GET", "first.bin", 3, None), requests)
                self.assertTrue(all(request[3] is None for request in requests))
                requests.clear()
                offline = {**environment, "HF_HUB_OFFLINE": "1"}
                result = subprocess.run(command, env=offline, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(requests, [])
                damaged = root / "huggingface/models--fixture--model/snapshots" / ("a" * 40) / "second.bin"
                damaged.resolve().unlink()
                result = subprocess.run(command, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(requests)
                self.assertEqual({request[1] for request in requests}, {"second.bin"})
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def test_reference_preparation_preserves_dataset(self):
        try:
            import pyarrow as pa
            import pyarrow.parquet as pq
        except ImportError:
            self.skipTest("pyarrow supplied by Nix package")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "reference.parquet"
            pq.write_table(
                pa.Table.from_pylist(
                    [{"name": "speaker", "audio": {"bytes": b"RIFFfixture"}, "transcription": "hello"}]
                ),
                dataset,
            )
            spec = {"file": dataset.name, "speaker": "speaker", "audio": "reference.wav", "textFile": "reference.txt"}
            prepare_reference(root, spec)
            self.assertEqual((root / "reference.wav").read_bytes(), b"RIFFfixture")
            self.assertEqual((root / "reference.txt").read_text(), "hello")
            self.assertTrue(dataset.exists())
            prepare_reference(root, spec)


if __name__ == "__main__":
    unittest.main()
