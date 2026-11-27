import argparse
import contextlib
import fcntl
import hashlib
import html
import http.server
import json
import mimetypes
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

TEMPLATE = Path(os.environ.get("MEDIA_GALLERY_TEMPLATE", Path(__file__).resolve().with_name("gallery.html")))
FONTS = Path(os.environ.get("MEDIA_GALLERY_FONTS", Path(__file__).resolve().with_name("fonts")))
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".bmp", ".svg", ".heic", ".tif", ".tiff"}
VIDEO_SUFFIXES = {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".ogv", ".avi"}
CONTENT_TYPES = {
    ".webp": "image/webp",
    ".avif": "image/avif",
    ".heic": "image/heic",
    ".svg": "image/svg+xml",
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".mov": "video/quicktime",
    ".webm": "video/webm",
    ".mkv": "video/x-matroska",
    ".ogv": "video/ogg",
}
STATUSES = ("review", "new", "done")
DEFAULT_SECTION = "Media"
FALLBACK_PORTS = range(8080, 8100)
THUMB_WIDTH = 640
# Keeps a page full of video thumbnails from starting dozens of ffmpeg processes at once.
THUMB_SLOTS = threading.BoundedSemaphore(3)
REGISTRY = Path(os.environ.get("MEDIA_GALLERY_REGISTRY") or Path.home() / ".local" / "state" / "media-gallery")
SLUG = re.compile(r"[A-Za-z0-9._-]+")


class GalleryError(Exception):
    pass


def repo_root(cwd=None):
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(out.stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        return Path(cwd or os.getcwd()).resolve()


def default_dir():
    if env := os.environ.get("MEDIA_GALLERY_DIR"):
        return Path(env)
    return repo_root() / ".tmp" / "gallery"


def empty_manifest(title):
    now = time.time()
    return {
        "version": 1,
        "title": title,
        "created": now,
        "updated": now,
        "next_id": 1,
        "batches": [],
        "sections": [],
        "items": [],
    }


def media_kind(path):
    suffix = path.suffix.lower()
    if suffix in IMAGE_SUFFIXES:
        return "image"
    if suffix in VIDEO_SUFFIXES:
        return "video"
    guessed, _ = mimetypes.guess_type(path.name)
    if guessed and guessed.split("/")[0] in ("image", "video"):
        return guessed.split("/")[0]
    return None


def content_type(path):
    return CONTENT_TYPES.get(path.suffix.lower()) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def probe(path):
    try:
        out = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height:format=duration",
                "-of",
                "json",
                str(path),
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        info = json.loads(out.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    result = {}
    streams = info.get("streams") or [{}]
    for key in ("width", "height"):
        if isinstance(streams[0].get(key), int):
            result[key] = streams[0][key]
    try:
        duration = float(info.get("format", {}).get("duration"))
        if duration > 0:
            result["duration"] = round(duration, 2)
    except (TypeError, ValueError):
        pass
    return result


def parse_range(header, size):
    """Return (start, end) inclusive, None for a full response, or raise ValueError when unsatisfiable."""
    if not header:
        return None
    match = re.fullmatch(r"\s*bytes=(\d*)-(\d*)\s*", header)
    if not match or match.groups() == ("", ""):
        return None
    first, last = match.groups()
    if first == "":
        start, end = max(0, size - int(last)), size - 1
    else:
        start = int(first)
        end = min(int(last), size - 1) if last else size - 1
    if size == 0 or start >= size or start > end:
        raise ValueError
    return start, end


class Gallery:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.manifest = self.root / "gallery.json"
        self.server_file = self.root / "server.json"
        self.thumbs = self.root / ".thumbs"

    @property
    def slug(self):
        named = (
            self.root.parent.parent if self.root.name == "gallery" and self.root.parent.name == ".tmp" else self.root
        )
        name = re.sub(r"[^A-Za-z0-9._-]+", "-", named.name).strip("-.") or "gallery"
        return f"{name}-{hashlib.sha1(str(self.root).encode()).hexdigest()[:6]}"

    def register(self):
        entry = REGISTRY / "galleries" / f"{self.slug}.json"
        content = json.dumps({"dir": str(self.root)}) + "\n"
        try:
            if entry.read_text() == content:
                return
        except OSError:
            pass
        entry.parent.mkdir(parents=True, exist_ok=True)
        tmp = entry.with_name(f".{entry.name}.{os.getpid()}.tmp")
        tmp.write_text(content)
        os.replace(tmp, entry)

    def unregister(self):
        (REGISTRY / "galleries" / f"{self.slug}.json").unlink(missing_ok=True)

    def read(self):
        try:
            with self.manifest.open() as f:
                data = json.load(f)
        except FileNotFoundError:
            return empty_manifest(f"{repo_root(self.root.parent).name} gallery")
        data.pop("published", None)
        data.pop("batch", None)
        if "batches" not in data:
            data["batches"] = [{"id": 1, "title": "", "created": data["created"]}] if data["items"] else []
        for item in data["items"]:
            item.setdefault("batch", 1)
            item.setdefault("history", [])
        return data

    @contextlib.contextmanager
    def edit(self):
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / ".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = self.read()
            yield data
            data["updated"] = time.time()
            tmp = self.manifest.with_name("gallery.json.tmp")
            tmp.write_text(json.dumps(data, indent=2) + "\n")
            os.replace(tmp, self.manifest)
        with contextlib.suppress(OSError):
            self.register()

    def item(self, data, item_id):
        return next((i for i in data["items"] if i["id"] == str(item_id)), None)

    def view(self):
        data = self.read()
        items = []
        for item in data["items"]:
            path = Path(item["path"])
            try:
                stat = path.stat()
                size, version, missing = stat.st_size, stat.st_mtime_ns, False
            except OSError:
                size, version, missing = None, 0, True
            entry = {
                k: item.get(k)
                for k in ("id", "kind", "section", "status", "caption", "note", "ask", "added", "batch", "history")
            }
            for key in ("width", "height", "duration"):
                if key in item:
                    entry[key] = item[key]
            entry.update(name=path.name, size=size, v=version, missing=missing)
            items.append(entry)
        return {
            "title": data["title"],
            "batches": data["batches"],
            "created": data["created"],
            "updated": data["updated"],
            "sections": data["sections"],
            "items": items,
        }

    def thumbnail(self, item):
        path = Path(item["path"])
        stat = path.stat()
        key = hashlib.sha1(f"{path}\0{stat.st_mtime_ns}\0{stat.st_size}".encode()).hexdigest()
        out = self.thumbs / f"{key}.jpg"
        if out.exists():
            return out
        with THUMB_SLOTS:
            if out.exists():
                return out
            self.thumbs.mkdir(parents=True, exist_ok=True)
            part = self.thumbs / f"{key}.{threading.get_ident()}.part.jpg"
            # Skip a second into a video to avoid black first frames; short clips retry from the start.
            seeks = [["-ss", "1"], []] if item["kind"] == "video" else [[]]
            for seek in seeks:
                try:
                    subprocess.run(
                        ["ffmpeg", "-nostdin", "-v", "error", "-y", *seek, "-i", str(path), "-frames:v", "1"]
                        + ["-vf", f"scale='min({THUMB_WIDTH},iw)':-2", "-q:v", "5", str(part)],
                        capture_output=True,
                        timeout=60,
                        check=True,
                    )
                except (OSError, subprocess.SubprocessError):
                    continue
                if part.exists() and part.stat().st_size > 0:
                    os.replace(part, out)
                    return out
            part.unlink(missing_ok=True)
        return None


def registered(slug):
    if not SLUG.fullmatch(slug):
        return None
    try:
        root = Path(json.loads((REGISTRY / "galleries" / f"{slug}.json").read_text())["dir"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    gallery = Gallery(root)
    return gallery if gallery.slug == slug and gallery.manifest.is_file() else None


def registered_galleries():
    found = []
    for entry in sorted((REGISTRY / "galleries").glob("*.json")):
        gallery = registered(entry.stem)
        if gallery:
            try:
                data = json.loads(gallery.manifest.read_text())
            except (OSError, ValueError):
                continue
            found.append((gallery, data))
    found.sort(key=lambda pair: pair[1].get("updated", 0), reverse=True)
    return found


def hub_index():
    rows = []
    for gallery, data in registered_galleries():
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(data.get("updated", 0)))
        review = sum(1 for item in data.get("items", []) if item.get("status") == "review")
        rows.append(
            f'<li><a href="g/{html.escape(gallery.slug)}/">{html.escape(data.get("title") or gallery.slug)}</a>'
            f"<span>{len(data.get('items', []))} items{f', {review} to review' if review else ''} · {when}</span>"
            f"<small>{html.escape(str(gallery.root))}</small></li>"
        )
    body = "".join(rows) or "<li>No galleries yet.</li>"
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Galleries</title>
<style>:root{{color-scheme:light dark}}body{{font:16px system-ui,sans-serif;max-width:48rem;margin:0 auto;padding:1.5rem 1rem}}
ul{{list-style:none;padding:0}}li{{padding:.75rem 0;border-bottom:1px solid #8884}}a{{font-weight:600;font-size:1.1rem}}
span,small{{display:block;opacity:.7}}small{{font-family:ui-monospace,monospace;font-size:.75rem;overflow-wrap:anywhere}}</style>
</head><body><h1>Galleries</h1><ul>{body}</ul></body></html>""".encode()


def make_handler(gallery=None):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "media-gallery"

        def log_request(self, code="-", size="-"):
            if isinstance(code, int) and code >= 400:
                super().log_request(code, size)

        def do_GET(self):
            self.route(body=True)

        def do_HEAD(self):
            self.route(body=False)

        def route(self, body):
            url = urllib.parse.urlsplit(self.path)
            parts = [p for p in url.path.split("/") if p]
            try:
                if gallery is not None:
                    self.gallery_route(gallery, parts, url, body)
                elif not parts:
                    self.send_bytes(hub_index(), "text/html; charset=utf-8", body, cache="no-cache")
                elif parts[0] == "g" and len(parts) >= 2 and (found := registered(parts[1])):
                    if len(parts) == 2 and not url.path.endswith("/"):
                        self.send_response(301)
                        self.send_header("Location", f"/g/{parts[1]}/")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                    else:
                        self.gallery_route(found, parts[2:], url, body)
                elif parts == ["favicon.ico"]:
                    self.send_bytes(b"", "image/x-icon", body)
                else:
                    self.send_json(404, {"error": "not found"}, body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def gallery_route(self, gallery, parts, url, body):
            if not parts or parts == ["index.html"]:
                self.send_bytes(TEMPLATE.read_bytes(), "text/html; charset=utf-8", body, cache="no-cache")
            elif parts == ["api", "gallery"]:
                payload = json.dumps(gallery.view()).encode()
                etag = '"' + hashlib.sha1(payload).hexdigest() + '"'
                if self.headers.get("If-None-Match") == etag:
                    self.send_response(304)
                    self.send_header("ETag", etag)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                else:
                    self.send_bytes(payload, "application/json", body, cache="no-cache", etag=etag)
            elif len(parts) == 2 and parts[0] in ("media", "thumb"):
                item = gallery.item(gallery.read(), parts[1])
                if not item or not Path(item["path"]).is_file():
                    self.send_json(404, {"error": "not found"}, body)
                elif parts[0] == "media":
                    query = urllib.parse.parse_qs(url.query)
                    self.send_file(Path(item["path"]), body, attachment="dl" in query)
                else:
                    thumb = gallery.thumbnail(item)
                    if thumb:
                        self.send_file(thumb, body, ctype="image/jpeg")
                    else:
                        self.send_json(404, {"error": "no thumbnail"}, body)
            elif len(parts) == 2 and parts[0] == "fonts" and re.fullmatch(r"[a-z0-9-]+\.woff2", parts[1]):
                font = FONTS / parts[1]
                if font.is_file():
                    self.send_file(font, body, ctype="font/woff2")
                else:
                    self.send_json(404, {"error": "not found"}, body)
            elif parts == ["favicon.ico"]:
                self.send_bytes(b"", "image/x-icon", body)
            else:
                self.send_json(404, {"error": "not found"}, body)

        def send_json(self, status, obj, body=True):
            self.send_bytes(json.dumps(obj).encode(), "application/json", body, status=status, cache="no-cache")

        def send_bytes(self, payload, ctype, body, status=200, cache=None, etag=None):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(payload)))
            if cache:
                self.send_header("Cache-Control", cache)
            if etag:
                self.send_header("ETag", etag)
            self.end_headers()
            if body:
                self.wfile.write(payload)

        def send_file(self, path, body, ctype=None, attachment=False):
            size = path.stat().st_size
            try:
                span = parse_range(self.headers.get("Range"), size)
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = span or (0, size - 1)
            length = max(0, end - start + 1)
            self.send_response(206 if span else 200)
            self.send_header("Content-Type", ctype or content_type(path))
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes")
            # Media URLs carry the file's mtime, so a changed file gets a new URL.
            self.send_header("Cache-Control", "private, max-age=86400")
            if attachment:
                quoted = urllib.parse.quote(path.name)
                self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quoted}")
            if span:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if not body:
                return
            with path.open("rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

    return Handler


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", port))
        except OSError:
            return False
    return True


def candidate_ports():
    listed = os.environ.get("AGENT_PREVIEW_PORTS", "").split()
    return [int(p) for p in listed if p.isdigit()] or list(FALLBACK_PORTS)


def lan_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("1.1.1.1", 80))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def public_url(port):
    return os.environ.get(f"AGENT_PREVIEW_URL_{port}") or f"http://{lan_address()}:{port}"


def running_server(gallery):
    try:
        info = json.loads(gallery.server_file.read_text())
        os.kill(info["pid"], 0)
        with socket.create_connection(("127.0.0.1", info["port"]), timeout=1):
            return info
    except (OSError, ValueError, KeyError):
        return None


HUB_FRESH = 90


def hub():
    """The host's gallery hub, when it answers."""
    try:
        path = REGISTRY / "hub.json"
        info = json.loads(path.read_text())
        # A running hub refreshes the file every 30 s. Sandboxes behind the egress proxy can't
        # reach its LAN address to probe it.
        if time.time() - path.stat().st_mtime < HUB_FRESH:
            return info
        target = urllib.parse.urlsplit(info["url"])
        with socket.create_connection((target.hostname, target.port or 80), timeout=1):
            return info
    except (OSError, ValueError, KeyError, TypeError):
        return None


def gallery_url(gallery, hub_info=None):
    info = hub_info or hub()
    if info:
        return f"{info['url'].rstrip('/')}/g/{gallery.slug}/"
    local = running_server(gallery)
    return local["url"] if local else None


def describe(item):
    label = f"#{item['id']} {Path(item['path']).name}"
    return f"{label} [{item['section']}]" + (f" {item['caption']}" if item.get("caption") else "")


def cmd_init(gallery, args):
    with gallery.edit() as data:
        title = args.title or data["title"]
        data.clear()
        data.update(empty_manifest(title))
    if gallery.thumbs.is_dir():
        for thumb in gallery.thumbs.iterdir():
            thumb.unlink(missing_ok=True)
    print(f"gallery reset: {gallery.manifest}")


def ensure_section(data, name, note=None):
    section = next((s for s in data["sections"] if s["name"] == name), None)
    if not section:
        section = {"name": name, "note": ""}
        data["sections"].append(section)
    if note is not None:
        section["note"] = note
    return section


def media_file(name):
    path = Path(name).expanduser().resolve()
    if not path.is_file():
        raise GalleryError(f"not a file: {name}")
    kind = media_kind(path)
    if not kind:
        raise GalleryError(f"not an image or video: {name}")
    return path, kind, probe(path)


def current_batch(data, title=None):
    if not data["batches"]:
        data["batches"].append({"id": 1, "title": title or "", "created": time.time()})
    return data["batches"][-1]["id"]


def put_item(data, path, kind, info, status, batch):
    item = next((i for i in data["items"] if i["path"] == str(path)), None)
    if item is None:
        item = {"id": str(data["next_id"]), "path": str(path), "history": []}
        data["next_id"] += 1
        data["items"].append(item)
    elif item.get("batch") != batch:
        item.setdefault("history", []).append(item["batch"])
    item.update(kind=kind, status=status, added=time.time(), batch=batch, **info)
    return item


def cmd_add(gallery, args):
    files = [media_file(name) for name in args.files]
    with gallery.edit() as data:
        if args.title:
            data["title"] = args.title
        batch = current_batch(data)
        for path, kind, info in files:
            item = put_item(data, path, kind, info, args.status, batch)
            item["section"] = args.section or item.get("section") or DEFAULT_SECTION
            for key in ("caption", "note", "ask"):
                if getattr(args, key) is not None or key not in item:
                    item[key] = getattr(args, key) or ""
            ensure_section(data, item["section"], args.section_note)
            print(f"{describe(item)} ({args.status})")
    hint_url(gallery)


BATCH_KEYS = {"title", "keep", "sections", "items"}
ITEM_KEYS = {"path", "status", "section", "caption", "note", "ask"}


def parse_spec(text, base):
    try:
        spec = json.loads(text)
    except ValueError as e:
        raise GalleryError(f"batch spec is not valid JSON: {e}") from None
    if not isinstance(spec, dict):
        raise GalleryError("batch spec must be a JSON object")
    if unknown := set(spec) - BATCH_KEYS:
        raise GalleryError(f"unknown batch keys: {', '.join(sorted(unknown))}")
    sections = spec.get("sections", {})
    if not isinstance(sections, dict) or not all(isinstance(v, str) for v in sections.values()):
        raise GalleryError('"sections" must map section names to notes')
    items = spec.get("items")
    if not isinstance(items, list) or not items:
        raise GalleryError('"items" must be a non-empty list')
    entries, seen = [], set()
    for n, entry in enumerate(items, 1):
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise GalleryError(f'item {n} needs a "path"')
        if unknown := set(entry) - ITEM_KEYS:
            raise GalleryError(f"item {n}: unknown keys: {', '.join(sorted(unknown))}")
        if entry.get("status", "new") not in STATUSES:
            raise GalleryError(f"item {n}: status must be one of {', '.join(STATUSES)}")
        for key in ITEM_KEYS - {"path", "status"}:
            if not isinstance(entry.get(key, ""), str):
                raise GalleryError(f"item {n}: {key} must be a string")
        path, kind, info = media_file(base / Path(entry["path"]).expanduser())
        if path in seen:
            raise GalleryError(f"item {n}: {entry['path']} is listed twice")
        seen.add(path)
        entries.append((entry, path, kind, info))
    title = spec.get("title", "")
    if not isinstance(title, str):
        raise GalleryError('"title" must be a string')
    return title, bool(spec.get("keep")), sections, entries


def cmd_batch(gallery, args):
    text = Path(args.file).read_text() if args.file and args.file != "-" else sys.stdin.read()
    title, keep, sections, entries = parse_spec(text, Path.cwd())
    with gallery.edit() as data:
        retired = []
        if not keep:
            for item in data["items"]:
                if item["status"] in ("review", "new"):
                    item["status"] = "done"
                    retired.append(f"#{item['id']}")
        batch = (data["batches"][-1]["id"] + 1) if data["batches"] else 1
        data["batches"].append({"id": batch, "title": title, "created": time.time()})
        for name, note in sections.items():
            ensure_section(data, name, note)
        print(f"batch {batch}" + (f": {title}" if title else ""))
        if retired:
            print(f"earlier review and new items marked done: {' '.join(retired)}")
        for entry, path, kind, info in entries:
            status = entry.get("status", "new")
            item = put_item(data, path, kind, info, status, batch)
            item["section"] = entry.get("section") or item.get("section") or DEFAULT_SECTION
            for key in ("caption", "note", "ask"):
                item[key] = entry.get(key, "")
            ensure_section(data, item["section"])
            print(f"{status:<6} {describe(item)}")
    hint_url(gallery)


def cmd_mark(gallery, args):
    with gallery.edit() as data:
        items = data["items"] if args.all else [select(gallery, data, i) for i in args.ids]
        for item in items:
            item["status"] = args.status
            print(f"{describe(item)} -> {args.status}")


def cmd_edit(gallery, args):
    with gallery.edit() as data:
        item = select(gallery, data, args.id)
        for key in ("caption", "note", "ask", "section"):
            if getattr(args, key) is not None:
                item[key] = getattr(args, key)
        ensure_section(data, item["section"])
        print(describe(item))


def cmd_remove(gallery, args):
    with gallery.edit() as data:
        for item_id in args.ids:
            data["items"].remove(select(gallery, data, item_id))
        used = {i["section"] for i in data["items"]}
        data["sections"] = [s for s in data["sections"] if s["name"] in used]


def cmd_section(gallery, args):
    with gallery.edit() as data:
        ensure_section(data, args.name, args.note)


def select(gallery, data, item_id):
    item = gallery.item(data, str(item_id).lstrip("#"))
    if not item:
        raise GalleryError(f"no item #{item_id}")
    return item


def cmd_list(gallery, args):
    data = gallery.read()
    print(f"{data['title']} ({len(data['items'])} items) {gallery.manifest}")
    for item in data["items"]:
        print(f"{item['status']:<6} b{item['batch']:<3} {describe(item)}")
    hint_url(gallery)


def hint_url(gallery):
    url = gallery_url(gallery)
    print(f"gallery: {url}" if url else "gallery not served; run: media-gallery serve")


def cmd_serve(gallery, args):
    if not gallery.manifest.exists():
        with gallery.edit():
            pass
    gallery.register()
    hub_info = None if args.local else hub()
    if hub_info:
        print(gallery_url(gallery, hub_info))
        return
    info = running_server(gallery)
    if info:
        print(info["url"])
        return
    if not args.local:
        print(
            "media-gallery: the gallery hub isn't running, so this link only lasts while this session's "
            "server does (start it on the host: systemctl --user start media-gallery)",
            file=sys.stderr,
        )
    port = args.port or next((p for p in candidate_ports() if port_free(p)), None)
    if not port:
        raise GalleryError("no free preview port")
    log = (gallery.root / "server.log").open("ab")
    proc = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--dir", str(gallery.root), "_run", "--port", str(port)],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise GalleryError(f"server exited; see {gallery.root / 'server.log'}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                break
        except OSError:
            time.sleep(0.1)
    else:
        proc.terminate()
        raise GalleryError("server did not start")
    url = public_url(port)
    gallery.server_file.write_text(json.dumps({"pid": proc.pid, "port": port, "url": url}) + "\n")
    print(url)


def cmd_stop(gallery, args):
    info = running_server(gallery)
    if info:
        os.kill(info["pid"], signal.SIGTERM)
        print(f"stopped {info['url']}")
    gallery.server_file.unlink(missing_ok=True)
    gallery.unregister()
    print(f"unpublished {gallery.slug}")


def cmd_url(gallery, args):
    url = gallery_url(gallery)
    if not url:
        raise GalleryError("not served; run: media-gallery serve")
    print(url)


def discover(roots):
    for root in roots:
        for pattern in (".tmp/gallery/gallery.json", "*/.tmp/gallery/gallery.json", "*/*/.tmp/gallery/gallery.json"):
            for manifest in Path(root).expanduser().glob(pattern):
                with contextlib.suppress(OSError):
                    Gallery(manifest.parent).register()


def publish_hub(url, port):
    try:
        if json.loads((REGISTRY / "hub.json").read_text()).get("url") == url:
            os.utime(REGISTRY / "hub.json")
            return
    except (OSError, ValueError, AttributeError):
        pass
    REGISTRY.mkdir(parents=True, exist_ok=True)
    tmp = REGISTRY / ".hub.json.tmp"
    tmp.write_text(json.dumps({"url": url, "port": port}) + "\n")
    os.replace(tmp, REGISTRY / "hub.json")
    print(f"media-gallery hub on {url}", flush=True)


def cmd_hub(gallery, args):
    discover(args.discover)
    server = Server((args.bind, args.port), make_handler())
    port = server.server_address[1]

    # The LAN address can arrive or change after the service starts.
    def keep_published():
        while True:
            publish_hub(args.url or f"http://{lan_address()}:{port}", port)
            time.sleep(30)

    threading.Thread(target=keep_published, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    server.serve_forever()


def cmd_run(gallery, args):
    server = Server(("0.0.0.0", args.port), make_handler(gallery))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    server.serve_forever()


def parser():
    p = argparse.ArgumentParser(
        prog="media-gallery",
        description="Build and serve a live, mobile-friendly gallery of images and videos for review.",
    )
    p.add_argument("--dir", type=Path, help="gallery directory (default: <repo>/.tmp/gallery)")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("init", help="start a fresh gallery, dropping all items")
    s.add_argument("--title")
    s.set_defaults(func=cmd_init)

    s = sub.add_parser(
        "batch",
        help="start a new batch from a JSON spec, marking earlier review and new items done",
        description='Spec: {"title": str, "keep": bool, "sections": {name: note}, "items": [{"path", "status" '
        '(review|new|done), "section", "caption", "note", "ask"}]}. Paths are relative to the working directory.',
    )
    s.add_argument("file", nargs="?", help="spec file (default: stdin)")
    s.set_defaults(func=cmd_batch)

    s = sub.add_parser("add", help="add files to the current batch, or refresh ones already in the gallery")
    s.add_argument("files", nargs="+")
    s.add_argument("--section", help=f"group heading (default: the item's current one, else {DEFAULT_SECTION})")
    s.add_argument("--section-note", help="text shown under the section heading")
    status = s.add_mutually_exclusive_group()
    status.add_argument("--review", dest="status", action="store_const", const="review", help="pin under Needs review")
    status.add_argument("--done", dest="status", action="store_const", const="done", help="plain item")
    s.set_defaults(status="new")
    s.add_argument("--caption")
    s.add_argument("--note", help="longer context shown in the viewer")
    s.add_argument("--ask", help="question or request for the human, shown under the item")
    s.add_argument("--title", help="gallery title")
    s.set_defaults(func=cmd_add)

    s = sub.add_parser("mark", help="change items' status")
    s.add_argument("ids", nargs="*")
    s.add_argument("--all", action="store_true")
    status = s.add_mutually_exclusive_group(required=True)
    for name in STATUSES:
        status.add_argument(f"--{name}", dest="status", action="store_const", const=name)
    s.set_defaults(func=cmd_mark)

    s = sub.add_parser("edit", help="change an item's caption, note or section")
    s.add_argument("id")
    s.add_argument("--caption")
    s.add_argument("--note")
    s.add_argument("--ask")
    s.add_argument("--section")
    s.set_defaults(func=cmd_edit)

    s = sub.add_parser("remove", help="drop items from the gallery (files stay)")
    s.add_argument("ids", nargs="+")
    s.set_defaults(func=cmd_remove)

    s = sub.add_parser("section", help="create a section or set its note")
    s.add_argument("name")
    s.add_argument("--note")
    s.set_defaults(func=cmd_section)

    s = sub.add_parser("list", help="print every item")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("serve", help="publish on the host's gallery hub (or a local server) and print the URL")
    s.add_argument("--local", action="store_true", help="run a server for this session instead of the hub")
    s.add_argument("--port", type=int, help="port for a local server")
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("url", help="print the gallery's URL")
    s.set_defaults(func=cmd_url)

    s = sub.add_parser("stop", help="unpublish the gallery and stop any local server")
    s.set_defaults(func=cmd_stop)

    s = sub.add_parser("hub", help="serve every registered gallery (the long-running host service)")
    s.add_argument("--port", type=int, default=8070)
    s.add_argument("--bind", default="0.0.0.0")
    s.add_argument("--url", help="public base URL (default: http://<LAN address>:<port>)")
    s.add_argument("--discover", nargs="*", default=[], help="register galleries found under these roots")
    s.set_defaults(func=cmd_hub)

    s = sub.add_parser("_run")
    s.add_argument("--port", type=int, required=True)
    s.set_defaults(func=cmd_run)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "mark" and not args.ids and not args.all:
        parser().error("mark needs item ids or --all")
    gallery = None if args.command == "hub" else Gallery(args.dir or default_dir())
    try:
        args.func(gallery, args)
    except GalleryError as e:
        print(f"media-gallery: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
