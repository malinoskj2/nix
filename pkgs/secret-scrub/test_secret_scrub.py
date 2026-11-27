import secrets
import sqlite3
import string
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("secret_scrub.py")


def fake_token():
    alphabet = string.ascii_letters + string.digits
    return "hf_" + "".join(secrets.choice(alphabet) for _ in range(35))


class ScrubTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.token = fake_token()
        (self.dir / "sessions").mkdir()
        self.rollout = self.dir / "sessions" / "rollout-1.jsonl"
        self.rollout.write_text(f'{{"out":"HF_TOKEN={self.token}"}}\n{{"ok":1}}\n')
        (self.dir / "clean.jsonl").write_text('{"ok":1}\n')
        (self.dir / "Code Cache" / "js").mkdir(parents=True)
        (self.dir / "Code Cache" / "js" / "abc_0").write_bytes(b"\0" + self.token.encode())
        self.db = self.dir / "state.db"
        con = sqlite3.connect(self.db)
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, body TEXT, raw BLOB)")
        con.execute("CREATE VIRTUAL TABLE search USING fts5(body)")
        con.execute("INSERT INTO events (body, raw) VALUES (?, ?)", (f"x {self.token} y", self.token.encode()))
        con.execute("INSERT INTO search (body) VALUES (?)", (f"token {self.token}",))
        con.commit()
        con.close()

    def run_scrub(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args, str(self.dir)],
            capture_output=True,
            text=True,
        )

    def assert_no_leak(self, result):
        self.assertNotIn(self.token, result.stdout)
        self.assertNotIn(self.token, result.stderr)

    def raw_hits(self):
        needle = self.token[3:].encode()
        return [p for p in self.dir.rglob("*") if p.is_file() and needle in p.read_bytes()]

    def test_dry_run_reports_without_values(self):
        result = self.run_scrub()
        self.assert_no_leak(result)
        self.assertEqual(result.returncode, 1)
        self.assertIn("rollout-1.jsonl", result.stdout)
        self.assertIn("state.db", result.stdout)
        self.assertNotIn("clean.jsonl", result.stdout)
        self.assertTrue(self.raw_hits())

    def test_redact(self):
        result = self.run_scrub("--redact")
        self.assert_no_leak(result)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.raw_hits(), [])
        self.assertIn('"ok":1', self.rollout.read_text())
        con = sqlite3.connect(self.db)
        self.assertEqual(con.execute("SELECT count(*) FROM events").fetchone()[0], 1)
        self.assertEqual(con.execute("SELECT count(*) FROM search WHERE search MATCH 'token'").fetchone()[0], 1)
        self.assertEqual(con.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        con.close()
        self.assertEqual(self.run_scrub().returncode, 0)

    def test_purge_deletes_text(self):
        result = self.run_scrub("--purge")
        self.assert_no_leak(result)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.rollout.exists())
        self.assertTrue((self.dir / "clean.jsonl").exists())
        self.assertEqual(self.raw_hits(), [])

    def test_refuses_open_database(self):
        holder = sqlite3.connect(self.db)
        holder.execute("SELECT 1").fetchall()
        try:
            result = self.run_scrub("--redact")
        finally:
            holder.close()
        self.assert_no_leak(result)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing", result.stderr)


if __name__ == "__main__":
    unittest.main()
