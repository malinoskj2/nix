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
            flags["Cargo.toml"],
            ["-W", "clippy::pedantic", "-W", "clippy::unwrap_used", "-W", "unsafe_code"],
        )
        self.assertEqual(overrides, [])

    def test_project_allow_wins_and_is_reported(self):
        project = {
            "clippy::unwrap_used": rust_lints.Setting("clippy::unwrap_used", "allow", 0),
            "clippy::module_name_repetitions": rust_lints.Setting("clippy::module_name_repetitions", "allow", 0),
        }
        flags, overrides = rust_lints.merge_levels(OURS, {"Cargo.toml": project})
        flags = flags["Cargo.toml"]
        self.assertNotIn("clippy::unwrap_used", flags[: flags.index("unsafe_code")])
        self.assertEqual(flags[-4:], ["-A", "clippy::module_name_repetitions", "-A", "clippy::unwrap_used"])
        reported = {item.lint: item for item in overrides}
        self.assertEqual(reported["clippy::unwrap_used"].ours, "warn")
        self.assertIsNone(reported["clippy::module_name_repetitions"].ours)
        self.assertFalse(reported["clippy::unwrap_used"].mixed)

    def test_individual_levels_follow_every_group(self):
        ours = OURS | {"clippy::must_use_candidate": rust_lints.Setting("clippy::must_use_candidate", "allow", 0)}
        project = {"clippy::pedantic": rust_lints.Setting("clippy::pedantic", "warn", -1)}
        flags = rust_lints.merge_levels(ours, {"Cargo.toml": project})[0]["Cargo.toml"]
        self.assertEqual(flags[:2], ["-W", "clippy::pedantic"])
        self.assertLess(flags.index("clippy::pedantic"), flags.index("clippy::must_use_candidate"))
        self.assertEqual(flags[flags.index("clippy::must_use_candidate") - 1], "-A")

    def test_project_deny_is_kept(self):
        project = {"unsafe_code": rust_lints.Setting("unsafe_code", "forbid", 0)}
        flags = rust_lints.merge_levels(OURS, {"Cargo.toml": project})[0]["Cargo.toml"]
        self.assertEqual(flags[-2:], ["-F", "unsafe_code"])

    def test_each_member_keeps_its_own_levels(self):
        members = {
            "a/Cargo.toml": {"unsafe_code": rust_lints.Setting("unsafe_code", "allow", 0)},
            "b/Cargo.toml": {"unsafe_code": rust_lints.Setting("unsafe_code", "deny", 0)},
            "c/Cargo.toml": {},
        }
        flags, overrides = rust_lints.merge_levels(OURS, members)
        self.assertEqual(flags["a/Cargo.toml"][-2:], ["-A", "unsafe_code"])
        self.assertEqual(flags["b/Cargo.toml"][-2:], ["-D", "unsafe_code"])
        self.assertEqual(flags["c/Cargo.toml"][-2:], ["-W", "unsafe_code"])
        self.assertEqual(
            [(o.project, o.sources, o.mixed) for o in overrides],
            [("allow", ["a/Cargo.toml"], True), ("deny", ["b/Cargo.toml"], True)],
        )


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


class ExitStatus(unittest.TestCase):
    def test_unexplained_pass_failure_beats_findings(self):
        report = {
            "findings": [object()],
            "errors": ["dylint pass exited with status 42"],
            "passes": {"clippy": 0, "dylint": 42},
        }
        self.assertEqual(rust_lints.exit_status(report), rust_lints.EXIT_FAILURE)


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
        findings, errors, accounted = rust_lints.collect(messages, Path("/w"), OURS, {"detached_spawn"}, groups, seen)
        self.assertEqual(
            [(f.lint, f.tool, f.policy) for f in findings],
            [
                ("clippy::doc_markdown", "clippy", "warn"),
                ("detached_spawn", "dylint", "warn"),
            ],
        )
        self.assertEqual(len(errors), 1)
        self.assertTrue(accounted)

    def test_dependency_errors_are_kept_and_account_for_a_failure(self):
        messages = [
            self.message("E0425", file="../dep/src/lib.rs", level="error"),
            self.message("dead_code", file="../dep/src/lib.rs"),
        ]
        findings, errors, accounted = rust_lints.collect(messages, Path("/w/app"), OURS, set(), {}, set())
        self.assertEqual(findings, [])
        self.assertEqual(errors, ["r"])
        self.assertTrue(accounted)

    def test_warnings_alone_do_not_account_for_a_failure(self):
        _, _, accounted = rust_lints.collect([self.message("dead_code")], Path("/w"), OURS, set(), {}, set())
        self.assertFalse(accounted)

    def test_a_repeated_error_still_accounts_for_a_later_pass(self):
        seen = set()
        error = self.message("E0425", level="error")
        rust_lints.collect([error], Path("/w"), OURS, set(), {}, seen)
        _, errors, accounted = rust_lints.collect([error], Path("/w"), OURS, set(), {}, seen)
        self.assertEqual(errors, [])
        self.assertTrue(accounted)


if __name__ == "__main__":
    unittest.main()
