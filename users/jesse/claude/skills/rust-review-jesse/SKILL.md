---
name: rust-review-jesse
description: Review Rust changes for requirement coverage, correctness, data semantics, failure safety, bounded operation and design. Use for review-only requests and report findings without editing.
---

# Rust review

Use the target from `$ARGUMENTS` when present; otherwise use the request or
delegation. Explicit requirements and repository instructions define the review
bar. This workflow is read-only.

## Establish scope

- Honor an explicitly supplied path, commit range, branch or pull request.
- Otherwise inspect status, staged and unstaged changes, and relevant untracked
  files. If reviewing a branch, establish its upstream or merge base rather than
  guessing from the branch name.
- Identify the request, specification or acceptance criteria behind the change.
  Separate missing requirements evidence from implementation defects.
- Read the owning modules and tests plus only the relevant sections of project
  standards, architecture documents and decision records. Judge the change
  against those sources rather than its own description.

Trace changed inputs through parsing, domain conversion, persistence or external
effects, derived state and exposed results. Use focused, non-mutating checks when
they can confirm or reject a concrete concern; state when verification could not
be run.

## Mechanized rules

Run `rust-lints` (`--json` for a machine-readable report) at the workspace root
first. It applies the shared lint levels, `clippy.toml` and Dylint library to any
Cargo project without editing it, writing only under the target directory; it
needs an up-to-date `Cargo.lock`, since it runs Cargo with `--locked`. Each
member keeps its own lint settings, and the report lists where they differ from
ours.
Exit status 0 is clean, 1 findings, 2 a build or tool failure. Report findings
in the reviewed scope with their lint names, and project overrides that hide a
rule. `rust-lints --paths` prints the source of truth for these rules:
`lints.toml`, `clippy.toml` and the Dylint sources (`pkgs/rust-lints/` in the
Nix repository). Rules below that name a lint are enforced there; review only
what the lint cannot see. If `rust-lints` is unavailable or fails, report that
gap and check those rules by hand.

## Project structure

Use one of these two patterns: a single package with a library and thin binary
entry points, or a Cargo workspace with multiple focused crates. Start with the
single-package pattern; split into crates when independent consumers, dependency
boundaries or distinct responsibilities justify it. Keep business logic out of
`main.rs`. Organize modules by domain responsibility (catch-all names:
`catch_all_module`).
The names below are examples; create only modules and crates the project needs.

Single package with a library:

```text
project/
├── Cargo.toml
├── src/
│   ├── lib.rs          # Module declarations and public API
│   ├── main.rs         # Configuration, wiring, invocation, error reporting
│   ├── domain.rs       # Domain types and rules
│   ├── service.rs      # Application operations
│   ├── storage.rs      # Persistence adapter
│   └── error.rs        # Typed errors derived with thiserror
└── tests/
    └── workflow.rs    # Public API integration tests
```

Multiple crates in a workspace:

```text
project/
├── Cargo.toml          # [workspace], members, shared dependency versions
└── crates/
    ├── domain/
    │   ├── Cargo.toml
    │   └── src/lib.rs  # Domain types, rules and typed errors
    ├── storage/
    │   ├── Cargo.toml
    │   └── src/lib.rs  # Persistence; depends on domain
    └── app/
        ├── Cargo.toml
        ├── src/lib.rs  # Operations and wiring; uses domain and storage
        ├── src/main.rs # Thin executable; reports errors with anyhow
        └── tests/workflow.rs
```

Keep workspace dependencies acyclic and domain crates independent of application
entry points and infrastructure. Each crate owns its modules and integration
tests. Use nested module directories as a domain grows. Apply the chosen pattern
within the requested scope; do not turn a focused change into an unrelated
repository-wide reorganization.

Keep platform-specific code behind `cfg` at the OS and driver boundary so domain
logic, parsers, storage and workers build and test on every development and CI
platform. Gate whole modules and their `[target.'cfg(...)'.dependencies]` rather
than scattering `cfg` through shared logic.

## Module ownership

Avoid heavily nested logic within functions (`clippy::excessive_nesting` flags
the deepest): use guard clauses where they clarify control flow, split work at
cohesive responsibility boundaries, and consider whether deep nesting signals a
missing domain abstraction that should own the rules or state. Introduce an
abstraction when it clarifies those responsibilities.

- **Organize by responsibility.** Keep parsing, transport and lifecycle details
  under their owning feature. Split files when responsibilities separate.
- **Keep definitions near their behavior.** Types, errors, constants and helpers
  belong with their owner; expose a small public API.
- **Separate decisions from effects.** Policy takes observations and returns
  typed decisions, making it understandable and testable without external I/O.
- **Align state with resource lifetimes.** A connection owns its parser, partial
  input and schedule. Reconnects explicitly reset other cached observations.

## Conditional checks

Every conditional should select meaningful behavior, enforce an invariant or
handle a possible failure. Avoid checks already guaranteed by a parser,
validated type, preceding branch or resource ownership unless that guarantee
can change before use. Trace callers and state transitions before declaring a
check redundant; include error, restart and shutdown paths in that reasoning.
Preserve input validation, overflow and capacity checks, deadlines and cleanup
guards where their invariant is not otherwise guaranteed. Report proven
redundancies in the reviewed scope with their evidence. Reject replacing a
necessary check with `unwrap` or `expect`, or adding an abstraction merely to
eliminate an `if`.

## Fixed strings

Prefer named `const &str` values for long fixed text and repeated semantic
identifiers such as filenames, registry values and protocol names. Keep them
with their owning feature; use a small text module when UI copy obscures behavior.
Keep obvious one-off labels and typed error messages beside their variants when
that is clearer. Keep changeable configuration separate from fixed text and
avoid a catch-all global constants file or extracting every literal.

Prefer `const` when only the value matters; use `static` when a stable object
address, shared state or large stored data justifies it. For interpolated
messages, use a small formatting function when extraction helps readability:
`format!` requires a literal template. Do not introduce runtime template parsing,
string replacement or lazy allocation solely to centralize fixed text.

## Dependency choices

The shared `cargo-preferences` tool owns the crate preference catalogue. Run
`cargo preferences list` before choosing a dependency; run `cargo preferences
check` against the workspace when adding or changing dependencies. It checks
explicit alternatives among direct dependencies, including renamed, optional,
target-specific, build and dev dependencies, without judging transitives. Unknown
crates and handwritten replacements still need suitability review.

When establishing project policy, read `cargo preferences guide`. Use a reviewed
baseline to preserve suitable existing choices, and exact per-member exceptions
with reasons for justified alternatives. Never refresh a baseline to hide new
findings. Use project policy to require dependencies/features for actual roles
(e.g. `clap` with `derive` for an application CLI) and forbid dependencies at
explicit boundaries (e.g. `anyhow` in a domain-only crate). Do not require unused
crates. A mixed library/binary package still needs source-level boundary review.

Adopted projects run `cargo preferences check --deny-warnings` in CI alongside
Clippy and tests. Before adoption, warnings identify choices to assess, not a
mandate to migrate unrelated existing dependencies. Use Clippy's configured
API bans where applicable, and cargo-deny only for actual graph-wide bans, not
ordinary crate preferences. Do not modify policy during a review-only task.
If the tool is unavailable, report that verification gap and follow established
project policy; do not claim a pass or apply host configuration changes.

Before writing code for a problem that is not specific to the project, such as
a standard format, protocol, algorithm, data structure or platform API, look for
an established crate that already solves it and use it instead of writing the
same thing. Established means wide adoption and active maintenance: substantial
downloads and reverse dependencies on crates.io, use by well-known projects, or
a recognized maintainer or organization. Prefer the standard library or a crate
already in the dependency graph, and keep the code when the crate would add far
more than the task needs. Do not add an unknown crate with little adoption. If
one looks unusually good anyway, mention it with the evidence for user approval
and proceed without it unless approved.

Before adding or recommending a crate, check its current upstream maintenance
status and compatibility with the project's MSRV, target platforms and required
features. Use upstream repository and release evidence; a quiet release history
alone does not establish abandonment. If a preferred crate is abandoned or
unsuitable, choose a maintained alternative and explain the reason. The
error-handling requirement below is subject to this maintenance and suitability
check.

Respect explicit project requirements and suitable dependencies already in use.
These preferences do not justify unrelated migrations or treating a suitable
alternative as a correctness defect. Add only the crates and features needed.

## Error handling

Error handling must use `thiserror` and `anyhow`; this is a requirement, not a
preference, even when the existing code uses another error-handling approach.
Use `thiserror` derives for owned domain, adapter and reusable-library error
types; use `anyhow::Result` and `anyhow::Context` at executable and report-only
orchestration boundaries. Keep typed errors until the last caller that needs to
match them. Do not replace these crates with hand-written error boilerplate,
string errors or another error framework (`manual_error_impl`,
`stringly_error`). Add the dependencies to the crates
that use them; a library without a report-only boundary does not need artificial
`anyhow` conversions merely to use both crates.

An `#[error]` message names the failed step without repeating its source:
`thiserror_source_in_message`. Test the rendered chain where users see it.

`unwrap` outside tests: `clippy::unwrap_used`. Avoid `expect` where a
non-panicking form exists: destructuring instead of indexing,
`get_or_insert_with`, `try_from` with a returned error, checked arithmetic or a
value computed in a `const` context. Keep `expect` for invariants the types
cannot express, with a message stating the invariant.

## Enums

Model closed sets of states, outcomes and choices as enums whose variants carry
only the data valid in that variant.

- Replace a status field plus optional fields that only some states set with an
  enum such as `Starting(Running)`, `Recording(Running)` and `Paused`, so
  impossible combinations cannot be built. Give data that several variants
  share an accessor such as `fn running(&self) -> Option<&Running>`.
- Return an outcome enum from an operation with several meaningful results, such
  as `Fresh`, `Unchanged` and `Resized`, instead of a `bool`, a sentinel value or
  an error used as control flow. Keep `Result` for failures.
- A `bool` literal argument (`bool_literal_argument`) calls for a two-variant
  enum.
- Prefer an enum to a trait object when the crate owns a closed set of
  implementations; use a trait when callers supply them.
- Match domain enums exhaustively where the match makes a decision
  (`local_enum_wildcard_arm` covers enums of the same crate).

## Unsafe code and FFI

Deny `unsafe_code` at the crate level and enable it only in modules that cross an
FFI or OS boundary, with `#[expect(unsafe_code, reason = "...")]` naming the API
called. Keep the code above that boundary safe Rust, and prefer maintained safe
wrappers (`rustix`, `bytemuck` for plain-old-data casts, the platform's wrapper
crate) to hand-written bindings.

- One operation per `unsafe` block, with its `// SAFETY:` invariant
  (`clippy::undocumented_unsafe_blocks`). The one-operation rule is a review
  point, not a lint.
- Wrap every foreign handle, allocation and registration in an owning type whose
  `Drop` releases it. Tie function pointers and objects obtained from a loaded
  library to that library's lifetime, through a borrow or shared ownership, so
  the library cannot be unloaded first.
- Encode thread affinity in the type: a guard for a thread-bound context or
  apartment is `!Send`. `unsafe impl Send`/`Sync` needs a `SAFETY` comment
  (`clippy::undocumented_unsafe_blocks`).
- Check `#[repr(C)]` layouts and versioned structure sizes against the foreign
  headers at compile time with `const _: () = assert!(...)`, `size_of` and
  `offset_of!`.
- When teardown cannot prove the foreign side or device has finished with a
  resource, leak it rather than free memory that may still be in use.

## Lints

Follow the repository's lint configuration. When establishing one, paste
`lints.toml` into `[workspace.lints]` and copy `clippy.toml`, then allow only
the pedantic lints the project deliberately rejects. Suppress locally with
`#[expect(lint, reason = "...")]` (`clippy::allow_attributes`). CI runs `cargo
fmt --check`, `cargo clippy --locked --all-targets` and `cargo test --locked`
with warnings denied, and tests the declared `rust-version` in its own job. Do
not impose this policy on an existing project as unrelated work.

Report states encoded as flags or optional fields that an enum would rule out,
foreign resources without an owning type and unchecked foreign layouts as
findings.

Review against these structure and error-handling requirements. Report violations
in the reviewed scope without applying fixes or demanding unrelated restructuring.

## Formatting

Within functions, use a single blank line to separate meaningful logical steps
(such as validation, preparation, effects and results), keeping tightly related
statements together and short cohesive functions compact.

One empty line between items: `missing_item_separator`. Its findings in the
reviewed scope are findings, not optional style.

## Review priorities

1. **Requirement coverage:** requested behavior exists end to end, including
   material errors, restarts, shutdown and compatibility behavior.
2. **Correctness and semantics:** types preserve meaningful distinctions and
   units; exact values remain exact; absence is not silently converted; derived
   facts retain provenance; external input cannot trigger a panic; persisted
   formats load files written by older and newer versions.
3. **Failure safety:** atomic work commits completely or not at all; partial
   input is not recorded as complete; retries are safe; cancellation and errors
   leave valid state.
4. **Bounded operation:** bodies, deadlines, retries, backoff, fan-out, queues,
   pool acquisition, queries and result sizes have defensible limits (unbounded
   channels and timeout-less HTTP clients: `clippy.toml`); spawned tasks have
   owners and are joined (`detached_spawn`).
5. **Rust design:** ownership matches retention, async code does not block or
   hold guards across `.await` (`blocking_call_in_async`,
   `clippy::await_holding_lock`), domain states are typed, errors support caller
   policy, and abstractions own real rules rather than forwarding calls. Project structure
   follows the library or multi-crate workspace pattern above. States and
   outcomes are enums carrying per-variant data. `unsafe` stays in boundary
   modules with stated invariants, owning types and checked layouts.
   Hand-written code that duplicates an established crate's job, and a newly
   added crate with little adoption, are findings.
6. **CLI and error boundaries:** CLI syntax, defaults, conflicts and constrained
   values are represented by the parser and rejected before expensive services
   start. For full-featured application CLIs, `clap` derive is the default absent
   a repository convention or measured constraint. `thiserror` and `anyhow` are required. Typed errors
   remain available while callers need policy decisions; `anyhow` is confined to
   report-only application/orchestration boundaries with useful context. String
   matching on errors (`error_string_matching`) and premature type erasure are
   findings. Parser tests cover
   grammar changes; process-level tests are reserved for exit and output contracts.
7. **Tests and observability:** tests cover the behavior and material failure
   paths at the right boundary; diagnostics are actionable and do not expose
   secrets.

## Report

List findings first, ordered by impact. For each finding include the file and
line, triggering scenario, consequence, evidence and concrete correction. Keep
verified defects, requirement gaps, questions and residual risks distinct. Do
not report stylistic preference as a defect when several idiomatic designs meet
the repository's standards.

If nothing material is wrong, say so and name the checks performed and remaining
test gaps. Do not edit files or apply corrections during a review-only task.
