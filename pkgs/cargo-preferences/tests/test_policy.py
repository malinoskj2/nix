import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


TOOL = Path(__file__).resolve().parents[1] / "cargo_preferences.py"


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "project"
        self.root.mkdir()
        (self.root / "Cargo.toml").write_text('[workspace]\nmembers = ["app", "domain"]\nresolver = "2"\n')
        for name in ("chrono", "time", "clap", "anyhow", "thiserror", "other", "serde_json"):
            self.package(Path(self.temp.name) / "deps" / name, name)
        with (Path(self.temp.name) / "deps/clap/Cargo.toml").open("a") as output:
            output.write("[features]\nderive = []\n")
        self.member("app")
        self.member("domain")

    def package(self, directory, name, extra=""):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Cargo.toml").write_text(
            f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n[lib]\npath = "lib.rs"\n{extra}'
        )
        (directory / "lib.rs").write_text("")

    def member(self, name, extra=""):
        self.package(self.root / name, name, extra)

    def dep(self, name, alias=None, extra=""):
        path = Path(self.temp.name) / "deps" / name
        return f'{alias or name} = {{ package = "{name}", path = "{path}", {extra} }}\n'

    def run_tool(self, *args, code=0, cwd=None):
        result = subprocess.run(
            [sys.executable, str(TOOL), *args],
            cwd=cwd or self.root,
            capture_output=True,
            text=True,
            env={**os.environ, "CARGO_NET_OFFLINE": "true"},
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def findings(self, *args, code=0):
        return json.loads(self.run_tool("check", "--json", *args, code=code).stdout)

    def write_policy(self, body):
        (self.root / ".crate-policy.toml").write_text("version = 1\n" + body)

    def test_preferred_and_complementary_dependencies_pass_without_mutation(self):
        self.member("app", "[dependencies]\n" + self.dep("time") + self.dep("serde_json"))
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(self.findings("--deny-warnings"), [])
        after = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_renamed_dependency_is_warning_or_ci_failure(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono", alias="clock"))
        findings = self.findings()
        self.assertEqual(findings[0]["edge"]["dependency"], "chrono")
        self.assertIn("prefer time", findings[0]["message"])
        self.findings("--deny-warnings", code=1)

    def test_transitive_alternative_is_ignored(self):
        other = Path(self.temp.name) / "deps/other/Cargo.toml"
        with other.open("a") as output:
            output.write("[dependencies]\n" + self.dep("chrono"))
        self.member("app", "[dependencies]\n" + self.dep("other"))
        self.assertEqual(self.findings("--deny-warnings"), [])

    def test_inactive_optional_target_build_and_dev_dependencies_are_checked(self):
        self.member(
            "app",
            "[dependencies]\n"
            + self.dep("chrono", extra="optional = true")
            + "[dev-dependencies]\n"
            + self.dep("chrono")
            + "[target.'cfg(windows)'.build-dependencies]\n"
            + self.dep("chrono"),
        )
        edges = [item["edge"] for item in self.findings()]
        self.assertEqual({edge["kind"] for edge in edges}, {"normal", "dev", "build"})
        self.assertIn("cfg(windows)", {edge["target"] for edge in edges})

    def test_baseline_is_explicit_exclusive_and_scoped(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono"))
        self.run_tool("baseline", code=2)
        self.run_tool("baseline", "--reason", "Keep compatible public API")
        self.assertEqual(self.findings("--deny-warnings"), [])
        self.run_tool("baseline", "--reason", "Accidental overwrite", code=2)
        self.member("domain", "[dependencies]\n" + self.dep("chrono"))
        findings = self.findings("--deny-warnings", code=1)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["edge"]["member"], "domain/Cargo.toml")

    def test_baseline_does_not_accept_new_dependency_kind(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono"))
        self.run_tool("baseline", "--reason", "Existing choice")
        self.member("app", "[dependencies]\n" + self.dep("chrono") + "[dev-dependencies]\n" + self.dep("chrono"))
        self.assertEqual(self.findings()[0]["edge"]["kind"], "dev")

    def test_stale_baseline_fails(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono"))
        self.run_tool("baseline", "--reason", "Existing choice")
        self.member("app")
        self.assertIn("stale baseline", self.findings(code=1)[0]["message"])

    def test_exception_needs_exact_scope_and_reason(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono"))
        self.member("domain", "[dependencies]\n" + self.dep("chrono"))
        self.write_policy(
            '[[exceptions]]\nmember = "app/Cargo.toml"\ndependency = "chrono"\nreason = "Compatibility"\n'
        )
        findings = self.findings("--deny-warnings", code=1)
        self.assertEqual([item["edge"]["member"] for item in findings], ["domain/Cargo.toml"])
        self.write_policy('[[exceptions]]\nmember = "app/Cargo.toml"\ndependency = "chrono"\nreason = " "\n')
        self.run_tool("check", code=2)

    def test_explicit_boundaries_and_features(self):
        self.write_policy(
            '[[forbidden]]\nmember = "domain/Cargo.toml"\ndependency = "anyhow"\nreason = "Typed errors"\n'
            '[[required]]\nmember = "app/Cargo.toml"\ndependency = "clap"\nfeatures = ["derive"]\nreason = "CLI"\n'
        )
        self.member("domain", "[dependencies]\n" + self.dep("anyhow"))
        self.assertEqual(len(self.findings(code=1)), 2)
        self.member("domain")
        self.member("app", "[dependencies]\n" + self.dep("clap"))
        self.assertIn("derive", self.findings(code=1)[0]["message"])
        self.member("app", "[dependencies]\n" + self.dep("clap", extra='features = ["derive"]'))
        self.assertEqual(self.findings("--deny-warnings"), [])

    def test_workspace_inherited_features_and_member_cwd(self):
        with (self.root / "Cargo.toml").open("a") as output:
            output.write("[workspace.dependencies]\n" + self.dep("clap", extra='features = ["derive"]'))
        self.member("app", "[dependencies]\nclap = { workspace = true }\n")
        self.write_policy(
            '[[required]]\nmember = "app/Cargo.toml"\ndependency = "clap"\nfeatures = ["derive"]\nreason = "CLI"\n'
        )
        self.run_tool("check", "--deny-warnings", cwd=self.root / "app")

    def test_baseline_and_exception_cannot_override_hard_boundary(self):
        self.member("app", "[dependencies]\n" + self.dep("chrono"))
        self.run_tool("baseline", "--reason", "Existing choice")
        self.write_policy(
            '[[exceptions]]\nmember = "app/Cargo.toml"\ndependency = "chrono"\nreason = "Old API"\n'
            '[[forbidden]]\nmember = "app/Cargo.toml"\ndependency = "chrono"\nreason = "New boundary"\n'
        )
        self.assertEqual(self.findings(code=1)[0]["message"], "New boundary")

    def test_malformed_and_unknown_configuration_fails_closed(self):
        for body in (
            "typo = true\n",
            '[[required]]\nmember = "missing/Cargo.toml"\ndependency = "clap"\nreason = "CLI"\n',
            '[[required]]\nmember = "app/Cargo.toml"\ndependency = "clap"\nreason = "CLI"\nfeatures = "derive"\n',
        ):
            with self.subTest(body=body):
                self.write_policy(body)
                self.run_tool("check", code=2)
        (self.root / ".crate-policy.toml").unlink()
        (self.root / ".crate-policy-baseline.json").write_text('{"version": 1, "entries": "oops"}')
        self.run_tool("check", code=2)

    def test_missing_explicit_files_are_errors(self):
        self.run_tool("check", "--policy", "missing.toml", code=2)
        self.run_tool("check", "--baseline", "missing.json", code=2)

    def test_catalogue_override_and_cargo_subcommand(self):
        replacement = self.root / "preferences.toml"
        replacement.write_text(
            'version = 1\n[[preferences]]\npreferred = "chrono"\npurpose = "project dates"\nalternatives = ["time"]\n'
        )
        self.member("app", "[dependencies]\n" + self.dep("time"))
        result = self.run_tool("preferences", "check", "--preferences", str(replacement), "--deny-warnings", code=1)
        self.assertIn("prefer chrono", result.stdout)

    def test_invalid_cargo_project_is_an_error(self):
        self.run_tool("check", "--manifest-path", "absent/Cargo.toml", code=2)

    def test_list_and_guide_do_not_need_a_cargo_project(self):
        result = self.run_tool("list", cwd=Path(self.temp.name))
        self.assertIn("confique", result.stdout)
        self.assertIn("signal-hook", result.stdout)
        self.run_tool("guide", cwd=Path(self.temp.name))


if __name__ == "__main__":
    unittest.main()
