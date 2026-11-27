import argparse
import os
import re
import shutil
import sqlite3
import sys
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


def default_roots():
    home = Path.home()
    return [
        home / ".config/orca",
        home / ".codex/sessions",
        home / ".claude/projects",
        home / ".local/share/agent-sandbox/home/.codex/sessions",
    ]


def walk(roots):
    for root in roots:
        if root.is_file():
            yield root
        elif root.is_dir():
            for dirpath, _, names in os.walk(root):
                for name in names:
                    path = Path(dirpath) / name
                    if path.is_file() and not path.is_symlink():
                        yield path


def kind(path):
    name = path.name
    if any(name.endswith(s) for s in SIDECARS):
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


def count(path, regex):
    total = 0
    tail = b""
    with path.open("rb") as f:
        while chunk := f.read(1 << 22):
            data = tail + chunk
            total += len(regex.findall(data))
            tail = data[-256:]
            total -= len(regex.findall(tail))
    return total + len(regex.findall(tail))


def holders(path):
    target = os.path.realpath(path)
    found = set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    if os.readlink(f"{fd_dir}/{fd}").startswith(target):
                        found.add(int(pid))
                except OSError:
                    pass
        except OSError:
            pass
    return found


def redact_text(path, regex):
    if path.stat().st_size > MAX_TEXT_BYTES:
        return None
    data = path.read_bytes()
    new, n = regex.subn(REPLACEMENT, data)
    if n:
        tmp = path.with_name(f".{path.name}.scrub")
        tmp.write_bytes(new)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    return n


def redact_db(path, regex):
    pattern = re.compile(regex.pattern.decode())

    def scrub(value):
        if isinstance(value, str):
            return pattern.sub(REPLACEMENT.decode(), value)
        if isinstance(value, bytes):
            return regex.sub(REPLACEMENT, value)
        return value

    con = sqlite3.connect(path, isolation_level=None)
    try:
        con.create_function("scrub", 1, scrub, deterministic=True)
        con.execute("PRAGMA busy_timeout=5000")
        con.execute("BEGIN IMMEDIATE")
        changed = 0
        rows = con.execute(
            "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
        virtual = [n for n, sql in rows if (sql or "").upper().startswith("CREATE VIRTUAL")]
        tables = [n for n, _ in rows if not any(n.startswith(v + "_") for v in virtual)]
        for table in tables:
            q = '"' + table.replace('"', '""') + '"'
            try:
                cols = [r[1] for r in con.execute(f"PRAGMA table_info({q})")]
            except sqlite3.DatabaseError:
                continue
            for col in cols:
                c = '"' + col.replace('"', '""') + '"'
                try:
                    cur = con.execute(
                        f"UPDATE {q} SET {c} = scrub({c}) "
                        f"WHERE typeof({c}) IN ('text','blob') "
                        f"AND CAST({c} AS BLOB) LIKE '%hf\\_%' ESCAPE '\\' "
                        f"AND scrub({c}) IS NOT {c}"
                    )
                    changed += cur.rowcount
                except sqlite3.DatabaseError as e:
                    print(f"  skipped {table}.{col}: {e}", file=sys.stderr)
        con.execute("COMMIT")
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        con.execute("VACUUM")
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        ok = con.execute("PRAGMA integrity_check").fetchone()[0]
        return changed, ok
    finally:
        con.close()


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

    regex = re.compile(PATTERNS[args.pattern])
    roots = args.roots or default_roots()
    acting = args.redact or args.purge
    hits = []
    for path in walk(roots):
        try:
            k = kind(path)
            n = count(path, regex)
        except OSError as e:
            print(f"unreadable {path}: {e.strerror}", file=sys.stderr)
            continue
        if n:
            hits.append((path, k, n))

    if not hits:
        print("no matches")
        return 0
    for path, k, n in hits:
        print(f"{n:6d}  {k:7s}  {path}")
    if not acting:
        print(f"\n{len(hits)} files match. Rerun with --redact or --purge after rotating the token.")
        return 1

    failures = 0
    dbs = {path for path, k, _ in hits if k == "db"}
    dbs |= {
        Path(str(path)[: -len(s)]) for path, k, _ in hits if k == "sidecar" for s in SIDECARS if str(path).endswith(s)
    }
    for db in sorted(dbs):
        busy = holders(db)
        if busy:
            print(f"refusing {db}: open in pids {sorted(busy)}; quit Orca and its daemon first", file=sys.stderr)
            failures += 1
            continue
        changed, ok = redact_db(db, regex)
        print(f"redacted {changed} values in {db} (integrity: {ok})")
        if ok != "ok":
            failures += 1

    for path, k, _ in hits:
        if k == "text":
            if args.purge:
                path.unlink()
                print(f"deleted {path}")
            else:
                n = redact_text(path, regex)
                if n is None:
                    print(f"too large to redact in memory: {path}", file=sys.stderr)
                    failures += 1
                else:
                    print(f"redacted {n} in {path}")
        elif k == "cache":
            path.unlink()
            print(f"deleted cache file {path}")
        elif k == "other":
            print(f"not rewritten (binary or compressed): {path}", file=sys.stderr)
            failures += 1

    remaining = [(path, n) for path in walk(roots) if path.exists() for n in [count(path, regex)] if n]
    for path, n in remaining:
        print(f"still matching: {n} in {path}", file=sys.stderr)
    return 1 if failures or remaining else 0


if __name__ == "__main__":
    sys.exit(main())
