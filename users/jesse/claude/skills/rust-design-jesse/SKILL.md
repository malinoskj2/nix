---
name: rust-design-jesse
description: Design or explain Rust architecture, types and boundaries using the active repository's domain rules. Use for Rust design questions; use rust-build-jesse for implementation and rust-review-jesse for reviews.
---

# Rust design

Use the task from `$ARGUMENTS` when present; otherwise use the request or
delegation. Explicit requirements and repository instructions take precedence
over this guidance.

Start from the active repository. Find the workspace root, inspect the owning
module, its callers and nearby tests, and read only the documentation relevant
to the question. Treat a repository's Rust standards, architecture documents
and recorded decisions as authoritative for that project. When documentation
and code disagree, identify the conflict instead of silently choosing one.

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
declarations, imports or closely related constants.

Shape the recommendation around the domain:

- Put invalid states behind enums, newtypes, validated constructors and narrow
  APIs when doing so removes a real class of mistakes.
- Keep wire formats, persistence rows and domain values at their respective
  boundaries. Preserve distinctions such as missing versus zero, exact versus
  approximate values, and observed versus derived facts when the domain cares.
- Make ownership and lifetimes express who may retain or mutate data. Pass owned
  values across spawned tasks and other long-lived boundaries.
- Give async work bounds, an owner and a shutdown path. Treat cancellation and
  partial failure as normal behavior where they can occur.
- Return typed errors when callers make different decisions by failure kind.
  Add context at adapter boundaries and reserve panics for programmer errors.
- For a full-featured application CLI, prefer `clap`'s derive API unless the
  repository has another established parser. Represent constrained arguments
  with enums, newtypes and `FromStr` or typed value parsers so invalid syntax is
  rejected before application services start.
- Use `thiserror` for domain, adapter and reusable-library errors that callers
  inspect. Use `anyhow` at executable and orchestration boundaries where the only
  remaining action is to add context and report the failure. Do not erase an
  error into `anyhow::Error` before the last caller that needs to match it.
- Introduce a trait for a real capability boundary, caller-selected behavior,
  multiple implementations or a useful test seam. Avoid pass-through layers and
  speculative interfaces.
- Keep transactions and other atomicity boundaries with the operation whose
  invariant they protect. Make unsafe partial use difficult for callers.

Explain the recommended shape, the invariants it owns and the obligations left
to callers. Name any unresolved product decision that would materially change
the design. Do not edit code for a design-only request.
