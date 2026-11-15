"""Check direct Cargo dependencies against explicit, reviewable crate policy."""

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import subprocess
import sys
import tomllib


class PolicyError(Exception):
    pass


@dataclass(frozen=True, order=True)
class Edge:
    member: str
    dependency: str
    kind: str
    target: str


@dataclass(frozen=True)
class Finding:
    severity: str
    edge: Edge
    message: str


def read_toml(path):
    with path.open("rb") as source:
        return tomllib.load(source)


def fields(value, allowed, required, location):
    if not isinstance(value, dict):
        raise PolicyError(f"{location}: expected a table")
    unknown = value.keys() - allowed
    missing = required - value.keys()
    if unknown or missing:
        raise PolicyError(f"{location}: unknown fields {sorted(unknown)}, missing fields {sorted(missing)}")


def nonempty(value, location):
    if not isinstance(value, str) or not value.strip():
        raise PolicyError(f"{location}: expected a nonempty string")
    return value


def string_list(value, location):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise PolicyError(f"{location}: expected a list of nonempty strings")
    return value


def preferences(path):
    data = read_toml(path)
    fields(data, {"version", "preferences"}, {"version", "preferences"}, str(path))
    if type(data["version"]) is not int or data["version"] != 1:
        raise PolicyError(f"{path}: unsupported version")
    if not isinstance(data["preferences"], list):
        raise PolicyError(f"{path}: preferences must be an array")
    result = {}
    for rule in data["preferences"]:
        fields(rule, {"preferred", "purpose", "alternatives"}, {"preferred", "purpose", "alternatives"}, str(path))
        nonempty(rule["preferred"], "preferred")
        nonempty(rule["purpose"], "purpose")
        for alternative in string_list(rule["alternatives"], "alternatives"):
            if alternative in result:
                raise PolicyError(f"{path}: duplicate alternative {alternative}")
            result[alternative] = rule
    return data["preferences"], result


def cargo_metadata(manifest):
    command = ["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked", "--offline"]
    if manifest:
        command.extend(["--manifest-path", str(manifest)])
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise PolicyError(f"cargo metadata failed:\n{result.stderr.strip()}")
    return json.loads(result.stdout)


def dependencies(metadata):
    root = Path(metadata["workspace_root"]).resolve()
    members = set(metadata["workspace_members"])
    edges = {}
    manifests = set()
    for package in metadata["packages"]:
        if package["id"] not in members:
            continue
        try:
            member = Path(package["manifest_path"]).resolve().relative_to(root).as_posix()
        except ValueError as error:
            raise PolicyError("workspace member lies outside the workspace root") from error
        manifests.add(member)
        for dependency in package["dependencies"]:
            # Cargo's name is the real package name, even for renamed dependencies.
            edge = Edge(member, dependency["name"], dependency["kind"] or "normal", dependency["target"] or "")
            edges.setdefault(edge, set()).update(dependency["features"])
    return root, manifests, edges


def policy(path, manifests):
    data = read_toml(path) if path.exists() else {"version": 1}
    fields(data, {"version", "exceptions", "required", "forbidden"}, {"version"}, str(path))
    if type(data["version"]) is not int or data["version"] != 1:
        raise PolicyError(f"{path}: unsupported version")
    edge_fields = {"member", "dependency", "kind", "target"}
    result = {"exceptions": {}, "required": {}, "forbidden": {}}
    for section in result:
        entries = data.get(section, [])
        if not isinstance(entries, list):
            raise PolicyError(f"{section}: expected an array of tables")
        for entry in entries:
            extra = {"features", "reason"} if section == "required" else {"reason"}
            fields(entry, edge_fields | extra, {"member", "dependency", "reason"}, section)
            member = nonempty(entry["member"], "member")
            if member not in manifests:
                raise PolicyError(f"{section}: unknown workspace member {member}")
            dependency = nonempty(entry["dependency"], "dependency")
            kind = entry.get("kind", "normal")
            target = entry.get("target", "")
            if kind not in ("normal", "dev", "build") or not isinstance(target, str):
                raise PolicyError(f"{section}: invalid dependency kind or target")
            edge = Edge(member, dependency, kind, target)
            nonempty(entry["reason"], f"{section}.reason")
            if section == "required":
                string_list(entry.get("features", []), "required.features")
            if edge in result[section]:
                raise PolicyError(f"{section}: duplicate entry for {edge}")
            result[section][edge] = entry
    if result["required"].keys() & result["forbidden"].keys():
        raise PolicyError("a dependency cannot be both required and forbidden")
    return result


def baseline(path):
    if not path.exists():
        return set()
    data = json.loads(path.read_text())
    fields(data, {"version", "entries"}, {"version", "entries"}, str(path))
    if type(data["version"]) is not int or data["version"] != 1:
        raise PolicyError(f"{path}: unsupported baseline version")
    if not isinstance(data["entries"], list):
        raise PolicyError(f"{path}: entries must be an array")
    result = set()
    for entry in data["entries"]:
        fields(
            entry,
            {"member", "dependency", "kind", "target", "reason"},
            {"member", "dependency", "kind", "target", "reason"},
            str(path),
        )
        for name in ("member", "dependency", "reason"):
            nonempty(entry[name], name)
        if entry["kind"] not in ("normal", "dev", "build") or not isinstance(entry["target"], str):
            raise PolicyError(f"{path}: invalid dependency kind or target")
        edge = Edge(*(entry[name] for name in ("member", "dependency", "kind", "target")))
        if edge in result:
            raise PolicyError(f"{path}: duplicate baseline entry")
        result.add(edge)
    return result


def check(edges, rules, config, existing):
    findings = []
    for edge in sorted(edges):
        if edge in config["forbidden"]:
            findings.append(Finding("error", edge, config["forbidden"][edge]["reason"]))
        if edge.dependency in rules and edge not in existing and edge not in config["exceptions"]:
            rule = rules[edge.dependency]
            findings.append(
                Finding(
                    "warning",
                    edge,
                    f"prefer {rule['preferred']} for {rule['purpose']}; "
                    "use the preferred crate or record a suitability exception",
                )
            )
    for edge, requirement in sorted(config["required"].items()):
        if edge not in edges:
            findings.append(Finding("error", edge, f"required direct dependency: {requirement['reason']}"))
        else:
            missing = set(requirement.get("features", [])) - edges[edge]
            if missing:
                findings.append(
                    Finding(
                        "error",
                        edge,
                        f"missing explicitly declared features {sorted(missing)}: {requirement['reason']}",
                    )
                )
    # Stale entries cannot silently exempt a later reintroduction.
    for edge in sorted(existing - edges.keys()):
        findings.append(Finding("error", edge, "stale baseline entry; remove it"))
    for edge in sorted(config["exceptions"].keys() - edges.keys()):
        findings.append(Finding("error", edge, "stale exception; remove it"))
    return findings


def rules_for_edges(edges, rules):
    return {edge for edge in edges if edge.dependency in rules}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "baseline", "list", "guide"])
    parser.add_argument("--manifest-path", type=Path)
    parser.add_argument("--policy", type=Path, help="default: workspace/.crate-policy.toml")
    parser.add_argument("--baseline", type=Path, help="default: workspace/.crate-policy-baseline.json")
    parser.add_argument(
        "--preferences",
        type=Path,
        default=Path(__file__).with_name("preferences.toml"),
        help="replace the shipped preference map",
    )
    parser.add_argument("--reason", help="required rationale for baseline creation")
    parser.add_argument("--deny-warnings", action="store_true", help="fail CI on unaccepted alternatives")
    parser.add_argument("--json", action="store_true", help="emit check findings as JSON")
    args = parser.parse_args(argv)
    if args.command == "baseline" and (not args.reason or not args.reason.strip()):
        parser.error("baseline requires --reason explaining why the existing choices are retained")
    if args.reason and args.command != "baseline":
        parser.error("--reason is only valid with baseline")
    if args.json and args.command != "check":
        parser.error("--json is only valid with check")
    try:
        if args.command == "guide":
            print(Path(__file__).with_name("guide.md").read_text(), end="")
            return 0
        catalogue, rules = preferences(args.preferences)
        if args.command == "list":
            for rule in catalogue:
                print(f"{rule['preferred']}: {rule['purpose']}")
                print(f"  review alternatives: {', '.join(rule['alternatives'])}")
            return 0
        root, manifests, edges = dependencies(cargo_metadata(args.manifest_path))
        policy_path = args.policy or root / ".crate-policy.toml"
        baseline_path = args.baseline or root / ".crate-policy-baseline.json"
        if args.policy and not policy_path.is_file():
            raise PolicyError(f"policy file does not exist: {policy_path}")
        if args.command == "check" and args.baseline and not baseline_path.is_file():
            raise PolicyError(f"baseline file does not exist: {baseline_path}")
        config = policy(policy_path, manifests)
        if args.command == "baseline":
            # Exclusive creation prevents accidental acceptance of new violations.
            entries = [dict(asdict(edge), reason=args.reason) for edge in sorted(rules_for_edges(edges, rules))]
            with baseline_path.open("x") as output:
                json.dump({"version": 1, "entries": entries}, output, indent=2)
                output.write("\n")
            print(f"Wrote {len(entries)} existing preference exceptions to {baseline_path}; review before committing.")
            return 0
        findings = check(edges, rules, config, baseline(baseline_path))
        if args.json:
            print(json.dumps([asdict(finding) for finding in findings], indent=2))
        else:
            for finding in findings:
                edge = finding.edge
                target = f", {edge.target}" if edge.target else ""
                print(f"{edge.member}: {finding.severity}: {edge.dependency} ({edge.kind}{target}): {finding.message}")
            if not findings:
                print("Crate policy passed (direct dependencies only).")
        return int(any(item.severity == "error" or args.deny_warnings for item in findings))
    except (PolicyError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"cargo-preferences: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    # Cargo invokes cargo-foo as `cargo-foo foo ...`.
    arguments = sys.argv[1:]
    if arguments[:1] == ["preferences"]:
        arguments = arguments[1:]
    sys.exit(main(arguments))
