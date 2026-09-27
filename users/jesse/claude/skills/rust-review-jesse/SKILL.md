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

Review against these structure and error-handling requirements. Report violations
in the reviewed scope without applying fixes or demanding unrelated restructuring.

## Formatting

Require exactly one empty line between Rust items, including between free
functions and between methods in an `impl` block. Function or method definitions
must never be placed directly against each other. The empty line may be omitted
only between logically grouped non-function items, such as a compact group of
module declarations, imports or closely related constants. Treat violations in
the reviewed scope as findings rather than optional stylistic preferences.

## Review priorities

1. **Requirement coverage:** requested behavior exists end to end, including
   material errors, restarts, shutdown and compatibility behavior.
2. **Correctness and semantics:** types preserve meaningful distinctions and
   units; exact values remain exact; absence is not silently converted; derived
   facts retain provenance; external input cannot trigger a panic.
3. **Failure safety:** atomic work commits completely or not at all; partial
   input is not recorded as complete; retries are safe; cancellation and errors
   leave valid state.
4. **Bounded operation:** bodies, deadlines, retries, backoff, fan-out, queues,
   pool acquisition, queries and result sizes have defensible limits; spawned
   tasks have owners and are joined.
5. **Rust design:** ownership matches retention, async code does not block or
   hold guards across `.await`, domain states are typed, errors support caller
   policy, and abstractions own real rules rather than forwarding calls. Project structure
   follows the library or multi-crate workspace pattern above.
6. **CLI and error boundaries:** CLI syntax, defaults, conflicts and constrained
   values are represented by the parser and rejected before expensive services
   start. For full-featured application CLIs, `clap` derive is the default absent
   a repository convention or measured constraint. `thiserror` and `anyhow` are required. Typed errors
   remain available while callers need policy decisions; `anyhow` is confined to
   report-only application/orchestration boundaries with useful context. String
   matching on errors and premature type erasure are findings. Parser tests cover
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
