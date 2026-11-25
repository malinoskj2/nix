import contextlib
import io
import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import media_gallery as mg  # noqa: E402

REGISTRY = tempfile.TemporaryDirectory()
mg.REGISTRY = Path(REGISTRY.name)


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = mg.main(list(argv))
    return code, out.getvalue()


class GalleryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dir = self.root / "gallery"
        self.png = self.root / "a.png"
        self.png.write_bytes(b"\x89PNG" + bytes(range(256)) * 4)
        self.mp4 = self.root / "b.mp4"
        self.mp4.write_bytes(bytes(range(256)) * 40)

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *argv):
        return run("--dir", str(self.dir), *argv)

    def manifest(self):
        return json.loads((self.dir / "gallery.json").read_text())

    def test_add_assigns_ids_and_statuses(self):
        self.cli("add", str(self.png), "--review", "--section", "Hero", "--caption", "first")
        self.cli("add", str(self.mp4))
        items = self.manifest()["items"]
        self.assertEqual(
            [(i["id"], i["kind"], i["status"]) for i in items], [("1", "image", "review"), ("2", "video", "new")]
        )
        self.assertEqual(items[0]["section"], "Hero")
        self.assertEqual(items[1]["section"], mg.DEFAULT_SECTION)

    def test_readd_keeps_id(self):
        self.cli("add", str(self.png), "--review", "--caption", "v1")
        self.cli("add", str(self.png), "--done")
        item = self.manifest()["items"][0]
        self.assertEqual((item["id"], item["status"], item["caption"]), ("1", "done", "v1"))

    def test_rejects_non_media(self):
        text = self.root / "notes.txt"
        text.write_text("x")
        with contextlib.redirect_stderr(io.StringIO()):
            code, _ = self.cli("add", str(text))
        self.assertEqual(code, 1)

    def test_mark_and_remove(self):
        self.cli("add", str(self.png), str(self.mp4))
        self.cli("mark", "--all", "--done")
        self.assertEqual({i["status"] for i in self.manifest()["items"]}, {"done"})
        self.cli("remove", "#1")
        self.assertEqual([i["id"] for i in self.manifest()["items"]], ["2"])

    def statuses(self):
        return {i["id"]: i["status"] for i in self.manifest()["items"]}

    def batch(self, spec):
        path = self.root / "spec.json"
        path.write_text(json.dumps(spec))
        return self.cli("batch", str(path))

    def test_batch_retires_open_items_and_tracks_history(self):
        self.cli("add", str(self.png), "--review")
        self.cli("add", str(self.mp4))
        third = self.root / "c.png"
        third.write_bytes(b"x")
        self.batch(
            {
                "title": "Pass 2",
                "sections": {"Hero": "Warm grades"},
                "items": [
                    {"path": str(third), "status": "review", "section": "Hero", "ask": "Pick one?"},
                    {"path": str(self.png), "status": "review", "caption": "v2"},
                ],
            }
        )
        data = self.manifest()
        self.assertEqual(self.statuses(), {"1": "review", "2": "done", "3": "review"})
        self.assertEqual([(b["id"], b["title"]) for b in data["batches"]], [(1, ""), (2, "Pass 2")])
        by_id = {i["id"]: i for i in data["items"]}
        self.assertEqual((by_id["1"]["batch"], by_id["1"]["history"], by_id["1"]["caption"]), (2, [1], "v2"))
        self.assertEqual((by_id["2"]["batch"], by_id["3"]["ask"]), (1, "Pick one?"))
        self.assertEqual(data["sections"][-1], {"name": "Hero", "note": "Warm grades"})

    def test_batch_keep_leaves_open_items(self):
        self.cli("add", str(self.png), "--review")
        self.batch({"keep": True, "items": [{"path": str(self.mp4), "status": "review"}]})
        self.assertEqual(self.statuses(), {"1": "review", "2": "review"})

    def test_batch_is_all_or_nothing(self):
        self.cli("add", str(self.png), "--review")
        before = self.manifest()
        for spec in (
            {"items": [{"path": str(self.mp4)}, {"path": str(self.root / "missing.png")}]},
            {"items": [{"path": str(self.mp4), "colour": "red"}]},
            {"items": [{"path": str(self.mp4), "status": "maybe"}]},
            {"items": []},
            {"title": "x", "itmes": []},
        ):
            with contextlib.redirect_stderr(io.StringIO()):
                code, _ = self.batch(spec)
            self.assertEqual(code, 1, spec)
        self.assertEqual(self.manifest(), before)

    def test_reads_manifest_without_batches(self):
        self.cli("add", str(self.png))
        data = self.manifest()
        del data["batches"]
        for item in data["items"]:
            del item["batch"], item["history"]
        (self.dir / "gallery.json").write_text(json.dumps(data))
        view = mg.Gallery(self.dir).view()
        self.assertEqual(len(view["batches"]), 1)
        self.assertEqual((view["items"][0]["batch"], view["items"][0]["history"]), (1, []))


class RangeTest(unittest.TestCase):
    def test_ranges(self):
        self.assertIsNone(mg.parse_range(None, 100))
        self.assertEqual(mg.parse_range("bytes=0-", 100), (0, 99))
        self.assertEqual(mg.parse_range("bytes=10-19", 100), (10, 19))
        self.assertEqual(mg.parse_range("bytes=90-200", 100), (90, 99))
        self.assertEqual(mg.parse_range("bytes=-10", 100), (90, 99))
        with self.assertRaises(ValueError):
            mg.parse_range("bytes=100-", 100)


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.png = root / "a.png"
        self.png.write_bytes(bytes(range(256)) * 4)
        (root / "secret.png").write_bytes(b"secret")
        self.gallery = mg.Gallery(root / "gallery")
        run("--dir", str(self.gallery.root), "add", str(self.png), "--review")
        self.server = mg.Server(("127.0.0.1", 0), mg.make_handler(self.gallery))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def get(self, path, headers=None):
        return urllib.request.urlopen(urllib.request.Request(self.base + path, headers=headers or {}))

    def test_page(self):
        self.assertIn(b"<title>", self.get("/").read())

    def test_gallery_etag(self):
        r = self.get("/api/gallery")
        view = json.load(r)
        self.assertEqual(view["items"][0]["name"], "a.png")
        self.assertNotIn("path", view["items"][0])
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get("/api/gallery", {"If-None-Match": r.headers["ETag"]})
        self.assertEqual(e.exception.code, 304)

    def test_media_range(self):
        r = self.get("/media/1", {"Range": "bytes=4-7"})
        self.assertEqual(r.status, 206)
        self.assertEqual(r.headers["Content-Range"], "bytes 4-7/1024")
        self.assertEqual(r.read(), bytes([4, 5, 6, 7]))

    def test_download_attachment(self):
        self.assertIsNone(self.get("/media/1").headers["Content-Disposition"])
        self.assertEqual(
            self.get("/media/1?v=1&dl=1").headers["Content-Disposition"], "attachment; filename*=UTF-8''a.png"
        )

    def test_only_listed_files(self):
        for path in ("/media/2", "/media/..%2Fsecret.png", "/media/1/../../secret.png"):
            with self.assertRaises(urllib.error.HTTPError) as e:
                self.get(path)
            self.assertEqual(e.exception.code, 404)


class HubTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo = root / "project"
        self.dir = self.repo / ".tmp" / "gallery"
        self.png = self.repo / ".tmp" / "a.png"
        self.png.parent.mkdir(parents=True)
        self.png.write_bytes(bytes(range(256)) * 4)
        run("--dir", str(self.dir), "add", str(self.png), "--review")
        self.gallery = mg.Gallery(self.dir)
        self.server = mg.Server(("127.0.0.1", 0), mg.make_handler())
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.gallery.unregister()
        self.tmp.cleanup()

    def get(self, path):
        return urllib.request.urlopen(self.base + path)

    def test_slug_is_stable_and_named_after_the_repo(self):
        self.assertRegex(self.gallery.slug, r"^project-[0-9a-f]{6}$")
        self.assertEqual(self.gallery.slug, mg.Gallery(self.dir).slug)

    def test_serves_registered_gallery(self):
        prefix = f"/g/{self.gallery.slug}/"
        self.assertIn(b"<title>", self.get(prefix).read())
        self.assertEqual(json.load(self.get(prefix + "api/gallery"))["items"][0]["name"], "a.png")
        self.assertEqual(self.get(prefix + "media/1").read(), self.png.read_bytes())
        self.assertIn(self.gallery.slug.encode(), self.get("/").read())

    def test_unregistered_is_gone(self):
        self.gallery.unregister()
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get(f"/g/{self.gallery.slug}/api/gallery")
        self.assertEqual(e.exception.code, 404)

    def test_rejects_forged_entries(self):
        entry = mg.REGISTRY / "galleries" / "other-000000.json"
        entry.write_text(json.dumps({"dir": str(self.dir)}))
        try:
            with self.assertRaises(urllib.error.HTTPError):
                self.get("/g/other-000000/api/gallery")
        finally:
            entry.unlink()

    def test_discover_registers_existing_galleries(self):
        self.gallery.unregister()
        mg.discover([self.tmp.name])
        self.assertIsNotNone(mg.registered(self.gallery.slug))


if __name__ == "__main__":
    unittest.main()
