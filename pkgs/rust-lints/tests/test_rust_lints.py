import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import rust_lints  # noqa: E402

OURS = {
    "clippy::pedantic": rust_lints.Setting("clippy::pedantic", "warn", -1),
    "clippy::unwrap_used": rust_lints.Setting("clippy::unwrap_used", "warn", 0),
    "unsafe_code": rust_lints.Setting("unsafe_code", "deny", 0),
}


class MergeLevels(unittest.TestCase):
    def test_ours_are_warnings_with_groups_first(self):
        flags, overrides = rust_lints.merge_levels(OURS, {"Cargo.toml": {}})
        self.assertEqual(
            flags,
            ["-W", "clippy::pedantic", "-W", "clippy::unwrap_used", "-W", "unsafe_code"],
        )
        self.assertEqual(overrides, [])

    def test_project_allow_wins_and_is_reported(self):
        project = {
            "clippy::unwrap_used": rust_lints.Setting("clippy::unwrap_used", "allow", 0),
            "clippy::module_name_repetitions": rust_lints.Setting("clippy::module_name_repetitions", "allow", 0),
        }
        flags, overrides = rust_lints.merge_levels(OURS, {"Cargo.toml": project})
        self.assertNotIn("clippy::unwrap_used", flags[: flags.index("unsafe_code")])
        self.assertEqual(flags[-4:], ["-A", "clippy::module_name_repetitions", "-A", "clippy::unwrap_used"])
        reported = {item.lint: item for item in overrides}
        self.assertEqual(reported["clippy::unwrap_used"].ours, "warn")
        self.assertIsNone(reported["clippy::module_name_repetitions"].ours)
        self.assertFalse(reported["clippy::unwrap_used"].mixed)

    def test_project_deny_is_kept(self):
        project = {"unsafe_code": rust_lints.Setting("unsafe_code", "forbid", 0)}
        flags, _ = rust_lints.merge_levels(OURS, {"Cargo.toml": project})
        self.assertEqual(flags[-2:], ["-F", "unsafe_code"])

    def test_members_that_disagree_use_the_most_permissive_level(self):
        members = {
            "a/Cargo.toml": {"clippy::unwrap_used": rust_lints.Setting("clippy::unwrap_used", "allow", 0)},
            "b/Cargo.toml": {},
        }
        flags, overrides = rust_lints.merge_levels(OURS, members)
        self.assertEqual(flags[-2:], ["-A", "clippy::unwrap_used"])
        self.assertTrue(overrides[0].mixed)


class ClippyConfig(unittest.TestCase):
    def test_project_scalars_win_and_lists_extend(self):
        with tempfile.TemporaryDirectory() as root:
            Path(root, "clippy.toml").write_text(
                "excessive-nesting-threshold = 9\n"
                'disallowed-methods = [{ path = "std::sync::mpsc::channel", reason = "ok" }, "std::process::exit"]\n'
            )
            os.environ.pop("CLIPPY_CONF_DIR", None)
            merged, notes, overridden = rust_lints.merge_clippy_config(Path(root))
        self.assertEqual(merged["excessive-nesting-threshold"], 9)
        self.assertEqual(overridden, ["excessive-nesting-threshold"])
        paths = [entry["path"] if isinstance(entry, dict) else entry for entry in merged["disallowed-methods"]]
        self.assertEqual(paths.count("std::sync::mpsc::channel"), 1)
        self.assertIn("std::process::exit", paths)
        self.assertIn("tokio::sync::mpsc::unbounded_channel", paths)
        self.assertTrue(notes)


class Collect(unittest.TestCase):
    def message(self, code, file="src/lib.rs", level="warning"):
        return {
            "reason": "compiler-message",
            "message": {
                "message": "m",
                "level": level,
                "code": {"code": code} if code else None,
                "rendered": "r",
                "spans": [{"is_primary": True, "file_name": file, "line_start": 3, "column_start": 1}],
            },
        }

    def test_dedupes_and_classifies(self):
        seen = set()
        groups = {"clippy::pedantic": {"clippy::doc_markdown"}}
        messages = [
            self.message("clippy::doc_markdown"),
            self.message("clippy::doc_markdown"),
            self.message("detached_spawn"),
            self.message(None, level="error"),
            self.message("dead_code", file="/elsewhere/dep.rs"),
        ]
        findings, errors = rust_lints.collect(messages, Path("/w"), OURS, {"detached_spawn"}, groups, seen)
        self.assertEqual(
            [(f.lint, f.tool, f.policy) for f in findings],
            [
                ("clippy::doc_markdown", "clippy", "warn"),
                ("detached_spawn", "dylint", "warn"),
            ],
        )
        self.assertEqual(len(errors), 1)


if __name__ == "__main__":
    unittest.main()
