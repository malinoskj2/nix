import argparse
import json
import os
import subprocess
import sys
import tomllib
from dataclasses import asdict, dataclass, field
from pathlib import Path

import tomli_w

DATA_DIR = Path(os.environ.get("RUST_LINTS_DATA", Path(__file__).resolve().parent))
TOOLS = ("rust", "clippy", "rustdoc")
LIST_KEYS = ("disallowed-methods", "disallowed-types", "disallowed-macros")
LEVEL_RANK = {"allow": 0, "expect": 0, "warn": 1, "deny": 2, "forbid": 3}
EXIT_CLEAN = 0
EXIT_FINDINGS = 1
EXIT_FAILURE = 2


@dataclass(frozen=True)
class Setting:
    name: str
    level: str
    priority: int


@dataclass
class Override:
    lint: str
    ours: str | None
    project: str
    sources: list[str]
    mixed: bool = False


@dataclass
class Finding:
    lint: str
    tool: str
    level: str
    policy: str | None
    message: str
    file: str | None
    line: int | None
    column: int | None
    rendered: str = field(repr=False)


class RunError(Exception):
    pass


def parse_table(table: dict) -> dict[str, Setting]:
    settings = {}
    for tool in TOOLS:
        for lint, value in table.get(tool, {}).items():
            if isinstance(value, str):
                level, priority = value, 0
            else:
                level, priority = value.get("level", "warn"), value.get("priority", 0)
            name = lint if tool == "rust" else f"{tool}::{lint}"
            settings[name] = Setting(name, level, priority)
    return settings


def our_settings() -> dict[str, Setting]:
    with open(DATA_DIR / "lints.toml", "rb") as file:
        return parse_table(tomllib.load(file)["workspace"]["lints"])


def dylint_lints() -> list[str]:
    return (DATA_DIR / "dylint-lints.txt").read_text().split()


def load_toml(path: Path) -> dict:
    with open(path, "rb") as file:
        return tomllib.load(file)


def member_settings(metadata: dict) -> dict[str, dict[str, Setting]]:
    root = Path(metadata["workspace_root"])
    root_manifest = root / "Cargo.toml"
    workspace_lints = {}
    if root_manifest.is_file():
        workspace_lints = parse_table(load_toml(root_manifest).get("workspace", {}).get("lints", {}))
    members = set(metadata["workspace_members"])
    result = {}
    for package in metadata["packages"]:
        if package["id"] not in members:
            continue
        manifest = Path(package["manifest_path"])
        lints = load_toml(manifest).get("lints", {})
        label = str(manifest.relative_to(root)) if manifest.is_relative_to(root) else str(manifest)
        if lints.get("workspace") is True:
            result[label] = workspace_lints
        else:
            result[label] = parse_table(lints)
    return result


def merge_levels(ours: dict[str, Setting], members: dict[str, dict[str, Setting]]) -> tuple[list[str], list[Override]]:
    configured: dict[str, dict[str, Setting]] = {}
    for member, settings in members.items():
        for name, setting in settings.items():
            configured.setdefault(name, {})[member] = setting

    flags = [
        Setting(name, "warn", setting.priority)
        for name, setting in ours.items()
        if name not in configured and setting.level != "allow"
    ]

    overrides = []
    replay = []
    for name, by_member in sorted(configured.items()):
        levels = {setting.level for setting in by_member.values()}
        level = min(levels, key=lambda level: LEVEL_RANK.get(level, 1))
        priority = min(setting.priority for setting in by_member.values())
        mixed = len(levels) > 1 or len(by_member) < len(members)
        replay.append(Setting(name, level, priority))
        mine = ours.get(name)
        differs = mine.level != level if mine else level in ("allow", "expect")
        if differs or mixed:
            overrides.append(
                Override(
                    lint=name,
                    ours=mine.level if mine else None,
                    project=level,
                    sources=sorted(by_member),
                    mixed=mixed,
                )
            )

    ordered = sorted(flags, key=lambda s: s.priority) + sorted(replay, key=lambda s: s.priority)
    return [flag for setting in ordered for flag in level_flag(setting)], overrides


def level_flag(setting: Setting) -> list[str]:
    option = {"allow": "-A", "expect": "-A", "warn": "-W", "deny": "-D", "forbid": "-F"}
    return [option.get(setting.level, "-W"), setting.name]


def merge_clippy_config(root: Path) -> tuple[dict, list[str], list[str]]:
    merged = load_toml(DATA_DIR / "clippy.toml")
    notes = []
    project = None
    conf_dir = os.environ.get("CLIPPY_CONF_DIR")
    candidates = [Path(conf_dir)] if conf_dir else []
    candidates.append(root)
    for directory in candidates:
        for name in ("clippy.toml", ".clippy.toml"):
            if (directory / name).is_file():
                project = directory / name
                break
        if project:
            break
    overridden = []
    if project:
        notes.append(f"merged project clippy config {project}")
        for key, value in load_toml(project).items():
            if key in LIST_KEYS:
                paths = {entry["path"] if isinstance(entry, dict) else entry for entry in value}
                ours = [
                    entry
                    for entry in merged.get(key, [])
                    if (entry["path"] if isinstance(entry, dict) else entry) not in paths
                ]
                merged[key] = ours + value
            else:
                if key in merged and merged[key] != value:
                    overridden.append(key)
                merged[key] = value
    return merged, notes, overridden


def nested_clippy_configs(metadata: dict, root: Path) -> list[str]:
    found = []
    for package in metadata["packages"]:
        if package["id"] not in metadata["workspace_members"]:
            continue
        directory = Path(package["manifest_path"]).parent
        if directory == root:
            continue
        for name in ("clippy.toml", ".clippy.toml"):
            if (directory / name).is_file():
                found.append(str(directory / name))
    return found


def cargo_metadata(manifest_path: str | None, offline: bool) -> dict:
    command = ["cargo", "metadata", "--no-deps", "--format-version", "1"]
    if manifest_path:
        command += ["--manifest-path", manifest_path]
    if offline:
        command.append("--offline")
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RunError(f"cargo metadata failed:\n{result.stderr.strip()}")
    return json.loads(result.stdout)


def run_cargo(command: list[str], env: dict[str, str], log) -> tuple[int, list[dict]]:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    messages = []
    stdout, stderr = process.communicate()
    for line in stdout.splitlines():
        if line.startswith("{"):
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    log.write(stderr)
    return process.returncode, messages


def lint_tool(code: str, dylint: set[str]) -> str:
    if "::" in code:
        return code.split("::", 1)[0]
    return "dylint" if code in dylint else "rust"


def policy_level(code: str, ours: dict[str, Setting], dylint: set[str], groups: dict) -> str | None:
    if code in ours:
        return ours[code].level
    if code in dylint:
        return "warn"
    for group, members in groups.items():
        if code in members and group in ours:
            return ours[group].level
    return None


def collect(
    messages: list[dict],
    root: Path,
    ours: dict[str, Setting],
    dylint: set[str],
    groups: dict,
    seen: set,
) -> tuple[list[Finding], list[str]]:
    findings, errors = [], []
    for item in messages:
        if item.get("reason") != "compiler-message":
            continue
        message = item["message"]
        level = message.get("level")
        code = (message.get("code") or {}).get("code")
        if level not in ("warning", "error") or message.get("message", "").endswith("emitted"):
            continue
        primary = next((span for span in message.get("spans", []) if span.get("is_primary")), None)
        file = primary["file_name"] if primary else None
        if file and not Path(file).is_absolute():
            file = str(root / file)
        if file:
            path = Path(file)
            if not path.is_relative_to(root):
                continue
            file = str(path.relative_to(root))
        key = (code, file, primary and primary["line_start"], primary and primary["column_start"], message["message"])
        if key in seen:
            continue
        seen.add(key)
        if code is None or (level == "error" and not code_is_lint(code)):
            errors.append(message.get("rendered") or message["message"])
            continue
        findings.append(
            Finding(
                lint=code,
                tool=lint_tool(code, dylint),
                level=level,
                policy=policy_level(code, ours, dylint, groups),
                message=message["message"],
                file=file,
                line=primary["line_start"] if primary else None,
                column=primary["column_start"] if primary else None,
                rendered=message.get("rendered") or "",
            )
        )
    return findings, errors


def code_is_lint(code: str) -> bool:
    return not (code.startswith("E") and code[1:].isdigit())


def clippy_groups() -> dict[str, set[str]]:
    path = DATA_DIR / "clippy-groups.json"
    if not path.is_file():
        return {}
    return {
        f"clippy::{group}": {f"clippy::{lint}" for lint in lints}
        for group, lints in json.loads(path.read_text()).items()
    }


def build_env(base: dict[str, str]) -> dict[str, str]:
    env = dict(base)
    wrapper = env.get("RUSTC_WRAPPER", "")
    if wrapper and Path(wrapper).name != "rust-lints-rustc-wrapper":
        env["RUST_LINTS_RUSTC_WRAPPER"] = wrapper
    env["RUSTC_WRAPPER"] = str(DATA_DIR / "rust-lints-rustc-wrapper")
    env.pop("RUSTUP_TOOLCHAIN", None)
    return env


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="rust-lints",
        description="Run Jesse's Rust lint set (Clippy levels, clippy.toml and Dylint) on a Cargo project without modifying it.",
        epilog="Exit status: 0 clean, 1 findings, 2 the project failed to build or a tool failed.",
    )
    parser.add_argument("--manifest-path", help="Cargo.toml of the package or workspace")
    parser.add_argument(
        "--message-format",
        choices=("human", "json"),
        default="human",
        help="human-readable report (default) or one JSON document on stdout",
    )
    parser.add_argument("--json", action="store_const", const="json", dest="message_format")
    parser.add_argument("--verbose", "-v", action="store_true", help="print each rendered diagnostic")
    parser.add_argument("--offline", action="store_true", help="pass --offline to Cargo")
    parser.add_argument("--no-clippy", action="store_true", help="skip the Clippy pass")
    parser.add_argument("--no-dylint", action="store_true", help="skip the Dylint pass")
    parser.add_argument("--print-flags", action="store_true", help="print the merged lint flags and exit")
    parser.add_argument(
        "--paths", action="store_true", help="print where the lint levels, clippy.toml and Dylint sources live"
    )
    parser.add_argument("cargo_args", nargs="*", help="extra arguments for cargo check, after --")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    metadata = cargo_metadata(args.manifest_path, args.offline)
    root = Path(metadata["workspace_root"])
    target = Path(metadata["target_directory"])
    ours = our_settings()
    dylint = set(dylint_lints())
    groups = clippy_groups()
    flags, overrides = merge_levels(ours, member_settings(metadata))
    clippy_config, notes, config_overrides = merge_clippy_config(root)
    notes += [f"member clippy config not merged: {path}" for path in nested_clippy_configs(metadata, root)]

    report = {
        "workspace_root": str(root),
        "flags": flags,
        "project_overrides": [asdict(item) for item in overrides],
        "clippy_config_overrides": config_overrides,
        "notes": notes,
        "findings": [],
        "errors": [],
        "passes": {},
    }
    if args.print_flags:
        return report

    work = target / "rust-lints"
    conf_dir = work / "clippy-conf"
    conf_dir.mkdir(parents=True, exist_ok=True)
    (conf_dir / "clippy.toml").write_text(tomli_w.dumps(clippy_config))
    log_path = work / "cargo.log"

    env = build_env(os.environ)
    common = ["--message-format=json", "--all-targets", "--workspace", "--keep-going"]
    if args.offline:
        common.append("--offline")
    common += args.cargo_args
    manifest = ["--manifest-path", args.manifest_path] if args.manifest_path else []

    seen: set = set()
    with open(log_path, "w") as log:
        if not args.no_clippy:
            clippy_env = dict(env, CLIPPY_CONF_DIR=str(conf_dir))
            command = ["cargo", "clippy", "--target-dir", str(work / "clippy"), *manifest, *common, "--", *flags]
            status, messages = run_cargo(command, clippy_env, log)
            findings, errors = collect(messages, root, ours, dylint, groups, seen)
            report["findings"] += findings
            report["errors"] += errors
            report["passes"]["clippy"] = status
        if not args.no_dylint:
            command = [
                os.environ.get("RUST_LINTS_CARGO_DYLINT", "cargo-dylint"),
                "dylint",
                "--lib-path",
                str(library_path()),
                *manifest,
                "--",
                *common,
            ]
            status, messages = run_cargo(command, env, log)
            findings, errors = collect(messages, root, ours, dylint, groups, seen)
            report["findings"] += findings
            report["errors"] += errors
            report["passes"]["dylint"] = status
    report["log"] = str(log_path)
    return report


def library_path() -> Path:
    return next(path for path in (DATA_DIR / "lib").iterdir() if path.suffix == ".so")


def exit_status(report: dict) -> int:
    failed = any(status != 0 for status in report["passes"].values()) and not report["findings"]
    if report["errors"] or failed:
        return EXIT_FAILURE
    return EXIT_FINDINGS if report["findings"] else EXIT_CLEAN


def print_human(report: dict, verbose: bool) -> None:
    out = sys.stdout
    for override in report["project_overrides"]:
        mixed = ", differs between members" if override["mixed"] else ""
        ours = override["ours"] or "unset"
        out.write(
            f"project sets {override['lint']} = {override['project']} (ours: {ours}{mixed}) in {', '.join(override['sources'])}\n"
        )
    for key in report["clippy_config_overrides"]:
        out.write(f"project clippy.toml overrides `{key}`\n")
    for note in report["notes"]:
        out.write(f"note: {note}\n")
    findings = sorted(report["findings"], key=lambda f: (f.file or "", f.line or 0, f.column or 0, f.lint))
    for finding in findings:
        if verbose and finding.rendered:
            out.write(finding.rendered)
            continue
        location = f"{finding.file}:{finding.line}:{finding.column}" if finding.file else "<no location>"
        out.write(f"{location}: {finding.level} [{finding.lint}] {finding.message}\n")
    for error in report["errors"]:
        out.write(error if error.endswith("\n") else error + "\n")
    counts: dict[str, int] = {}
    for finding in findings:
        counts[finding.lint] = counts.get(finding.lint, 0) + 1
    if counts:
        out.write("\nfindings by lint:\n")
        for lint, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
            out.write(f"  {count:5} {lint}\n")
    status = exit_status(report)
    summary = {EXIT_CLEAN: "clean", EXIT_FINDINGS: f"{len(findings)} findings", EXIT_FAILURE: "failed"}[status]
    out.write(f"\nrust-lints: {summary}")
    if "log" in report:
        out.write(f" (cargo log: {report['log']})")
    out.write("\n")


def print_paths() -> None:
    for name, path in (
        ("lints.toml", DATA_DIR / "lints.toml"),
        ("clippy.toml", DATA_DIR / "clippy.toml"),
        ("dylint sources", DATA_DIR / "dylint" / "src"),
        ("dylint library", library_path()),
    ):
        sys.stdout.write(f"{name}: {path}\n")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.paths:
        print_paths()
        return EXIT_CLEAN
    try:
        report = run(args)
    except RunError as error:
        if args.message_format == "json":
            json.dump({"status": "failed", "errors": [str(error)]}, sys.stdout)
            sys.stdout.write("\n")
        else:
            sys.stderr.write(f"rust-lints: {error}\n")
        return EXIT_FAILURE
    if args.print_flags:
        if args.message_format == "json":
            json.dump(report, sys.stdout, indent=2)
            sys.stdout.write("\n")
        else:
            print_human(report, verbose=False)
            sys.stdout.write(" ".join(report["flags"]) + "\n")
        return EXIT_CLEAN
    status = exit_status(report)
    if args.message_format == "json":
        report["status"] = {EXIT_CLEAN: "clean", EXIT_FINDINGS: "findings", EXIT_FAILURE: "failed"}[status]
        report["findings"] = [{key: value for key, value in asdict(finding).items()} for finding in report["findings"]]
        json.dump(report, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print_human(report, args.verbose)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
