# Rust crate preferences

`cargo preferences` checks the workspace's direct dependency declarations using
`cargo metadata --no-deps --locked --offline`. It does not compile, download,
modify manifests or lockfiles, or inspect source code. Optional, target-specific,
build and development dependencies are included, even when inactive. Renaming a
dependency does not bypass its package-name rule. Transitive dependencies are
not judged by our preferences.

## Adoption and CI

Run `cargo preferences list` to see the maintained preference catalogue and its
explicit alternatives. The catalogue is the source of truth for machine checks;
it is not an exhaustive classification of crates. Unknown crates are not banned.
Review current upstream maintenance, MSRV, features and platform suitability
before choosing any crate, including a preferred one.

1. Run `cargo preferences check` to inspect current choices.
2. For an existing project, retain suitable choices with
   `cargo preferences baseline --reason 'Existing project choices reviewed for suitability'`.
   This creates `.crate-policy-baseline.json` exclusively: it will not overwrite
   an existing baseline. Review its entries and tailor their reasons before
   committing. Never regenerate a baseline to silence newly introduced findings.
   New projects generally do not need a baseline.
3. Record project boundaries in `.crate-policy.toml` as needed (examples below).
4. Run `cargo preferences check --deny-warnings` in CI alongside the repository's
   formatter, Clippy and tests. Commit policy and baseline with the code.

Without `--deny-warnings`, alternatives are warnings and exit successfully;
explicit requirement/boundary violations always fail. Exit codes: 0 passes,
1 has failing findings, 2 is an invocation/configuration/Cargo failure.
`check --json` emits findings with severity, member, dependency, kind, target and
message. Diagnostics from tool/configuration failures go to stderr.

A baseline accepts only existing preference findings. It cannot exempt a required
crate/feature or forbidden dependency. Removed dependencies leave stale baseline
or exception entries, which fail until removed. Acceptance is per member path,
package name, dependency kind and target; it survives version updates and local
aliases, but does not approve a new member or target. Version changes still need
compatibility review. The baseline is a committed acceptance record, not an
automatically inferred comparison with Git history.

Default policy/baseline paths are at Cargo's workspace root, even when invoked
from a member directory. Explicit file paths are relative to the caller's working
directory. `--manifest-path` selects a workspace through its manifest.

## Project policy

Every entry names an exact workspace-relative manifest, uses the real dependency
package name, and explains its reason. `kind` defaults to `normal` and `target`
to the unconditional dependency table (`""`). Unknown fields, unknown members
and duplicate entries fail, so a misspelled boundary cannot silently pass.

```toml
version = 1

# This crate has only domain responsibilities; it has no report-only boundary.
[[forbidden]]
member = "crates/domain/Cargo.toml"
dependency = "anyhow"
reason = "Callers need typed domain errors."

[[required]]
member = "crates/domain/Cargo.toml"
dependency = "thiserror"
reason = "This crate owns domain error types."

[[required]]
member = "crates/app/Cargo.toml"
dependency = "anyhow"
reason = "The application boundary adds context and reports failures."

[[required]]
member = "crates/app/Cargo.toml"
dependency = "clap"
features = ["derive"]
reason = "This application CLI declares its grammar using derive."

[[exceptions]]
member = "crates/app/Cargo.toml"
dependency = "chrono"
reason = "The existing public API exposes chrono types; preserve compatibility."

# To target a conditional or development dependency, add exactly:
# kind = "dev"
# target = "cfg(unix)"
```

Only declare requirements for responsibilities the project actually has. Do not
add unused `thiserror`, `anyhow` or `clap` dependencies just to satisfy a template.
A mixed library/binary package can legitimately depend on both error crates;
source-level boundary enforcement still belongs to Clippy/custom linting and
review. Requirements above check unconditional normal dependency declarations;
use separate entries to constrain other kinds or targets.

`features` requires explicit dependency features as reported by Cargo, including
workspace-inherited declarations. It does not infer activation through defaults,
feature forwarding or transitive feature unification. Omit a feature requirement
when the project intentionally uses those mechanisms and verify its build matrix.
Duplicate aliases for the same package/kind/target have their declared features
combined. This verifies declarations, not actual API usage.

Exceptions and baselines only waive preferences. Change an explicit project
requirement/boundary with a documented architecture decision when it no longer
applies; an exception cannot override it. Files under policy are reviewable code,
not a security boundary against someone who can modify CI.

## API choices and actual dependency bans

Use Clippy for selected prohibited methods, types and macros. For example, where
project policy forbids `std::env::args` in favor of a derive CLI, merge this into
`clippy.toml` (do not overwrite existing configuration):

```toml
disallowed-methods = [
    { path = "std::env::args", reason = "Parse application CLI input with clap derive." },
    { path = "std::env::args_os", reason = "Parse application CLI input with clap derive." },
]
```

Enable `clippy::disallowed_methods` in the package/workspace lint configuration;
workspace members must opt into shared lints with `[lints] workspace = true`.
Apply these bans only where the API really is prohibited. The preference checker
does not install Clippy settings or guess safe low-level API replacements.

Use `cargo deny check bans` for genuine graph-wide dependency or feature bans,
with a repository-owned `deny.toml`. Do not translate our preference catalogue
into graph-wide bans: a preferred library may legitimately bring in `libc`,
`chrono`, or another alternative transitively. cargo-deny is available in the Rust
tool environment but has no universal bans preset here.

To change the preference catalogue for a project, pass `--preferences path.toml`
consistently in local checks and CI. It replaces the shipped catalogue and uses
this schema (all fields required):

```toml
version = 1
[[preferences]]
preferred = "time"
purpose = "dates and timestamps"
alternatives = ["chrono", "jiff"]
```

The checker cannot determine whether handwritten code should use a library,
whether a source actually uses an installed dependency, whether an unsafe call
has a safe replacement, or whether a crate is well maintained. Those checks stay
in the build/design/review skills. Preferred crates remain subject to suitability
and explicit project instructions.
