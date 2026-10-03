---
name: rust-build-jesse
description: Implement or refactor Rust code using the active repository's requirements, domain rules and verification workflow. Use for requested Rust code changes; use rust-review-jesse for review-only work.
---

# Rust build

Use the task from `$ARGUMENTS` when present; otherwise use the request or
delegation. Complete the requested implementation and verification. Explicit
requirements and repository instructions take precedence over this guidance.

## Establish the change

- Inspect the working tree and preserve unrelated changes.
- Read the workspace manifests and the owning module, relevant callers and
  nearby tests. Use the versions and features the lockfile and manifests select.
- Read only the applicable sections of project standards, architecture documents
  and decision records. Do not preload an entire documentation stack for a small
  change.
- Translate the request into observable behavior, including material failure,
  restart, cancellation and compatibility behavior. Resolve routine choices from
  repository evidence; ask only when an unresolved product choice changes the
  outcome.

## Project structure

Use one of these two patterns: a single package with a library and thin binary
entry points, or a Cargo workspace with multiple focused crates. Start with the
single-package pattern; split into crates when independent consumers, dependency
boundaries or distinct responsibilities justify it. Keep business logic out of
`main.rs`. Organize modules by domain responsibility, not a catch-all `utils`.
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

## Module ownership

- **Organize by responsibility.** Keep parsing, transport and lifecycle details
  under their owning feature. Split files when responsibilities separate.
- **Keep definitions near their behavior.** Types, errors, constants and helpers
  belong with their owner; expose a small public API.
- **Separate decisions from effects.** Policy takes observations and returns
  typed decisions, making it understandable and testable without external I/O.
- **Align state with resource lifetimes.** A connection owns its parser, partial
  input and schedule. Reconnects explicitly reset other cached observations.

## Dependency choices

When choosing among dependencies for equivalent purposes, prefer these crates
when they fit the task and remain maintained:

- `clap` with its derive API for application CLI parsing.
- `confique` for typed, layered application configuration.
- `rustix` for safe wrappers around Unix/Linux system operations.
- `serde` for serialization and deserialization.
- `winnow` for parser combinators and structured text parsing.
- `thiserror` for typed errors and `anyhow` for context and reporting at
  executable or report-only orchestration boundaries.
- `time` for dates, timestamps, parsing and formatting.
- `signal-hook` for process signal handling.
- `xdg` for XDG configuration, data, cache and state directories.

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
string errors or another error framework. Add the dependencies to the crates
that use them; a library without a report-only boundary does not need artificial
`anyhow` conversions merely to use both crates.

## Formatting

Put exactly one empty line between Rust items, including between free functions
and between methods in an `impl` block. Never place function or method
definitions directly against each other. The empty line may be omitted only
between logically grouped non-function items, such as a compact group of module
declarations, imports or closely related constants. Preserve this spacing when
running rustfmt and check item boundaries in the final diff.

## Implement

Make the smallest coherent change that delivers the behavior through its real
entry point, domain logic and persistence or external boundary.

- Parse external representations at adapter boundaries and convert them into
  domain values before they spread through the application.
- Use enums, newtypes and validated constructors for distinctions and invariants
  that should survive refactoring. Preserve missing, stale, unavailable,
  approximate and derived states when they are meaningful; never invent a value
  to simplify a type.
- Store money and other exact quantities without binary floating point. Carry
  units, currency, scale, provenance or observation time when the domain needs
  them.
- Return errors with enough structure for callers to choose policy. Do not panic
  on configuration, network, input or database failures.
- For application CLIs, use the repository's established parser; when choosing
  one for a full-featured CLI, prefer `clap` with its derive API. Model commands
  with `Parser`, `Subcommand` and `Args`, closed values with `ValueEnum`, and
  other constrained values with typed fields or value parsers. Express syntax
  relationships with parser constraints and reject invalid CLI input before
  initializing databases, network clients or workers. Keep semantic validation
  that needs application state in the application layer.
- Use `thiserror` for typed domain, adapter and reusable-library errors, including
  `#[from]` or `#[source]` where the causal chain matters. Use `anyhow` for
  executable and orchestration functions whose caller only reports failure;
  attach actionable `Context` at I/O and subsystem boundaries. Keep a concrete
  error type until no caller needs to match on it, and avoid string inspection
  as control flow.
- Bound network bodies, deadlines, retries, concurrency, queues and result sets.
  Every spawned task needs an owner and a shutdown path; avoid blocking or
  holding a mutex guard across `.await`.
- Put related writes and read-check-write invariants in the appropriate
  transaction. Keep network work outside a database transaction unless the
  repository documents a reason otherwise.
- Prefer the repository's established libraries and module ownership. Add traits
  only for a real capability boundary, caller choice, shared behavior or useful
  test seam.

## Verify

Test observable behavior and the material failures introduced or changed. Use
focused unit tests for domain logic and the repository's real integration setup
for database, process or protocol semantics. Exercise a batch beyond its chunk
size when batching behavior changes. Test CLI grammar with `try_parse_from` (or
the established parser's equivalent) when commands, defaults, conflicts or value
validation change; do not spawn the full application merely to test parsing.
Use `assert_cmd` when exit status or stdout/stderr is the contract, and consider
`trycmd` only when a larger stable matrix benefits from snapshot cases.

Discover required checks from the repository's CI, task runner and scripts, then
run the checks relevant to the change. Normally this includes formatting,
Clippy with the repository's warning policy, focused tests and the broader test
target required by CI. Run architectural checks and measured performance or
statement baselines when the affected project defines them. Do not claim a check
passed when its service, fixture or toolchain was unavailable.

Read the final diff for requirement coverage and accidental scope. Report the
behavior changed, checks run and any material limitation.
