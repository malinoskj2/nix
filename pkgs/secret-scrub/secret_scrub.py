import argparse
import os
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

PATTERNS = {
    "hf": rb"hf_[A-Za-z0-9]{30,}",
}
REPLACEMENT = b"hf_REDACTED"
TEXT_SUFFIXES = {".jsonl", ".json", ".txt", ".md", ".log", ".ndjson"}
DB_SUFFIXES = {".db", ".sqlite", ".sqlite3"}
SIDECARS = ("-wal", "-shm", "-journal")
CACHE_DIRS = {"Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"}
MAX_TEXT_BYTES = 2 << 30


class Scrubber:
    def __init__(self, pattern):
        self.regex = re.compile(pattern)
        self.text_regex = re.compile(pattern.decode())
        self.failures = 0

    def safe(self, value):
        text = str(value)
        return self.text_regex.sub("hf_<hidden>", text.encode("utf-8", "replace").decode("utf-8", "replace"))

    def say(self, message, error=False):
        print(self.safe(message), file=sys.stderr if error else sys.stdout)

    def fail(self, message):
        self.failures += 1
        self.say(message, error=True)

    def walk(self, roots):
        for root in roots:
            if root.is_symlink():
                self.fail(f"skipped symlink root {root}")
            elif root.is_file():
                yield root
            elif root.is_dir():
                for dirpath, _, names in os.walk(root, onerror=lambda e: self.fail(f"cannot list {e.filename}")):
                    for name in names:
                        path = Path(dirpath) / name
                        if path.is_file() and not path.is_symlink():
                            yield path

    def kind(self, path):
        if any(path.name.endswith(s) for s in SIDECARS):
            return "sidecar"
        if CACHE_DIRS.intersection(p.name for p in path.parents):
            return "cache"
        if path.suffix in DB_SUFFIXES:
            return "db"
        with path.open("rb") as f:
            if f.read(16) == b"SQLite format 3\x00":
                return "db"
        if path.suffix in TEXT_SUFFIXES:
            return "text"
        return "other"

    def count(self, path):
        total = 0
        tail = b""
        with path.open("rb") as f:
            while chunk := f.read(1 << 22):
                data = tail + chunk
                total += len(self.regex.findall(data))
                tail = data[-256:]
                total -= len(self.regex.findall(tail))
        return total + len(self.regex.findall(tail))

    def scrub_value(self, value):
        if isinstance(value, str):
            return self.text_regex.sub(REPLACEMENT.decode(), value)
        if isinstance(value, bytes):
            return self.regex.sub(REPLACEMENT, value)
        return value

    def hit(self, value):
        if isinstance(value, str):
            return self.text_regex.search(value) is not None
        if isinstance(value, bytes):
            return self.regex.search(value) is not None
        return False

    def columns(self, con):
        rows = con.execute(
            "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
        virtual = [n for n, sql in rows if (sql or "").upper().startswith("CREATE VIRTUAL")]
        for table, _ in rows:
            if any(table.startswith(v + "_") for v in virtual):
                continue
            q = '"' + table.replace('"', '""') + '"'
            for row in con.execute(f"PRAGMA table_xinfo({q})"):
                col = row[1]
                yield table in virtual, q, '"' + col.replace('"', '""') + '"'

    def open_db(self, path, readonly):
        uri = f"file:{path}?mode=ro" if readonly else f"file:{path}?mode=rw"
        con = sqlite3.connect(uri, uri=True, isolation_level=None)
        con.create_function("scrub", 1, self.scrub_value, deterministic=True)
        con.create_function("hit", 1, self.hit, deterministic=True)
        con.execute("PRAGMA busy_timeout=5000")
        return con

    def logical_hits(self, path):
        con = self.open_db(path, readonly=True)
        try:
            total = 0
            for _, q, c in self.columns(con):
                total += con.execute(f"SELECT count(*) FROM {q} WHERE hit({c})").fetchone()[0]
            return total
        finally:
            con.close()

    def redact_db(self, path):
        con = self.open_db(path, readonly=False)
        try:
            con.execute("BEGIN IMMEDIATE")
            changed = 0
            for is_virtual, q, c in self.columns(con):
                try:
                    changed += con.execute(f"UPDATE {q} SET {c} = scrub({c}) WHERE hit({c})").rowcount
                except sqlite3.DatabaseError as e:
                    kind = "virtual table" if is_virtual else "table"
                    self.fail(f"could not update a column of a {kind} in {path} ({type(e).__name__})")
            con.execute("COMMIT")
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            con.execute("VACUUM")
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            ok = con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            return changed, ok
        finally:
            con.close()

    def redact_text(self, path):
        if path.stat().st_size > MAX_TEXT_BYTES:
            return None
        data = path.read_bytes()
        new, n = self.regex.subn(REPLACEMENT, data)
        if not n:
            return 0
        st = path.stat()
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".scrub")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(new)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, st.st_mode & 0o7777)
            os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
        return n

    def scan(self, roots):
        files, dbs = [], set()
        for path in self.walk(roots):
            try:
                k = self.kind(path)
                if k == "sidecar":
                    base = Path(next(str(path)[: -len(s)] for s in SIDECARS if str(path).endswith(s)))
                    if base.exists():
                        dbs.add(base)
                    n = self.count(path)
                    if n and not base.exists():
                        files.append((path, "other", n))
                    continue
                if k == "db":
                    dbs.add(path)
                    continue
                n = self.count(path)
            except OSError as e:
                self.fail(f"unreadable {path} ({type(e).__name__})")
                continue
            if n:
                files.append((path, k, n))
        db_hits = []
        for db in sorted(dbs):
            try:
                logical = self.logical_hits(db)
                physical = sum(self.count(p) for p in [db, *(Path(f"{db}{s}") for s in SIDECARS)] if p.exists())
            except (OSError, sqlite3.Error) as e:
                self.fail(f"could not inspect database {db} ({type(e).__name__})")
                continue
            if logical or physical:
                db_hits.append((db, logical, physical))
        return files, db_hits


def default_roots():
    home = Path.home()
    return [
        home / ".config/orca",
        home / ".codex/sessions",
        home / ".claude/projects",
        home / ".local/share/agent-sandbox/home/.codex/sessions",
    ]


def holders(path):
    targets = {os.path.realpath(f"{path}{s}") for s in ("", *SIDECARS)}
    found = set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    if os.readlink(f"{fd_dir}/{fd}") in targets:
                        found.add(int(pid))
                except OSError:
                    pass
        except OSError:
            pass
    return found


def run(args, s):
    roots = args.roots or default_roots()
    files, dbs = s.scan(roots)
    for path, k, n in files:
        s.say(f"{n:6d}  {k:7s}  {path}")
    for db, logical, physical in dbs:
        s.say(f"{logical:6d}  db       {db} (raw bytes: {physical})")
    if not (args.redact or args.purge):
        if files or dbs:
            s.say(f"\n{len(files) + len(dbs)} files match. Rerun with --redact or --purge after rotating the token.")
            return 1
        if s.failures:
            return 1
        s.say("no matches")
        return 0

    for db, _, _ in dbs:
        busy = holders(db)
        if busy:
            s.fail(f"refusing {db}: open in pids {sorted(busy)}; quit Orca and its daemon first")
            continue
        try:
            changed, ok = s.redact_db(db)
        except sqlite3.Error as e:
            s.fail(f"could not redact {db} ({type(e).__name__})")
            continue
        s.say(f"redacted {changed} values in {db}")
        if not ok:
            s.fail(f"integrity check failed for {db}")

    for path, k, _ in files:
        try:
            if k == "text" and args.purge:
                path.unlink()
                s.say(f"deleted {path}")
            elif k == "text":
                n = s.redact_text(path)
                if n is None:
                    s.fail(f"too large to redact in memory: {path}")
                else:
                    s.say(f"redacted {n} in {path}")
            elif k == "cache":
                path.unlink()
                s.say(f"deleted cache file {path}")
            else:
                s.fail(f"not rewritten (binary or compressed): {path}")
        except OSError as e:
            s.fail(f"could not rewrite {path} ({type(e).__name__})")

    after = Scrubber(s.regex.pattern)
    files, dbs = after.scan(roots)
    for path, _, n in files:
        s.fail(f"still matching: {n} in {path}")
    for db, logical, physical in dbs:
        s.fail(f"still matching in {db}: {logical} values, {physical} raw")
    return 1 if s.failures or after.failures else 0


def main():
    p = argparse.ArgumentParser(
        description="Find, redact or delete leaked tokens in agent transcripts and Orca state. "
        "Prints paths and match counts only, never the matched values."
    )
    p.add_argument("roots", nargs="*", type=Path, help="files or directories (default: agent transcript locations)")
    p.add_argument("--pattern", choices=sorted(PATTERNS), default="hf")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--redact", action="store_true", help="rewrite matches in place")
    mode.add_argument("--purge", action="store_true", help="delete text files that match; databases are redacted")
    args = p.parse_args()
    s = Scrubber(PATTERNS[args.pattern])
    try:
        return run(args, s)
    except BaseException as e:
        if isinstance(e, SystemExit):
            raise
        s.say(f"aborted: {type(e).__name__}", error=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
