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

Keep platform-specific code behind `cfg` at the OS and driver boundary so domain
logic, parsers, storage and workers build and test on every development and CI
platform. Gate whole modules and their `[target.'cfg(...)'.dependencies]` rather
than scattering `cfg` through shared logic.

## Module ownership

Avoid heavily nested logic within functions: use guard clauses where they clarify
control flow, split work at cohesive responsibility boundaries, and consider
whether deep nesting signals a missing domain abstraction that should own the
rules or state. Introduce an abstraction when it clarifies those responsibilities.

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
guards where their invariant is not otherwise guaranteed. Simplify within the
requested scope; never replace a necessary check with `unwrap` or `expect`, or
add an abstraction merely to eliminate an `if`.

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

A `thiserror` variant that carries its cause through `#[from]` or `#[source]`
must not repeat that cause in its `#[error]` message. The message names the step
that failed; the cause is printed once when the chain is reported (`{:#}` on
`anyhow::Error`, or a walk of `source()`). Test the rendered chain where users
see it.

Outside tests, avoid `unwrap` and `expect` wherever a non-panicking form exists:
destructuring instead of indexing, `get_or_insert_with`, `try_from` with a
returned error, checked arithmetic or a value computed in a `const` context.
Keep `expect` for invariants the types cannot express, with a message stating
the invariant.

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
- Use a two-variant enum instead of a `bool` parameter when the call site would
  otherwise read `f(true)`.
- Prefer an enum to a trait object when the crate owns a closed set of
  implementations; use a trait when callers supply them.
- Match domain enums exhaustively where the match makes a decision, without a
  wildcard arm, so a new variant forces each dependent decision to be revisited.

## Unsafe code and FFI

Deny `unsafe_code` at the crate level and enable it only in modules that cross an
FFI or OS boundary, with `#[expect(unsafe_code, reason = "...")]` naming the API
called. Keep the code above that boundary safe Rust, and prefer maintained safe
wrappers (`rustix`, `bytemuck` for plain-old-data casts, the platform's wrapper
crate) to hand-written bindings.

- Each `unsafe` block performs one unsafe operation and carries a `// SAFETY:`
  comment stating the invariant that makes it sound.
- Wrap every foreign handle, allocation and registration in an owning type whose
  `Drop` releases it. Tie function pointers and objects obtained from a loaded
  library to that library's lifetime, through a borrow or shared ownership, so
  the library cannot be unloaded first.
- Encode thread affinity in the type: a guard for a thread-bound context or
  apartment is `!Send`. Never implement `Send` or `Sync` without a `SAFETY`
  comment justifying it.
- Check `#[repr(C)]` layouts and versioned structure sizes against the foreign
  headers at compile time with `const _: () = assert!(...)`, `size_of` and
  `offset_of!`.
- When teardown cannot prove the foreign side or device has finished with a
  resource, leak it rather than free memory that may still be in use.

## Lints

Follow the repository's lint configuration. When establishing one, use
`[lints]` in `Cargo.toml`: deny `unsafe_code`; warn on `unreachable_pub`;
enable Clippy's `pedantic` group at priority -1 together with
`undocumented_unsafe_blocks`, `multiple_unsafe_ops_per_block` and
`allow_attributes_without_reason`; and allow only the pedantic lints the project
deliberately rejects. Suppress a lint locally with
`#[expect(lint, reason = "...")]` rather than `#[allow]`, so a suppression that
no longer applies is reported. CI runs `cargo fmt --check`,
`cargo clippy --locked --all-targets` and `cargo test --locked` with warnings
denied, and tests the declared `rust-version` in its own job. Do not impose this
policy on an existing project as unrelated work.

## Formatting

Within functions, use a single blank line to separate meaningful logical steps
(such as validation, preparation, effects and results), keeping tightly related
statements together and short cohesive functions compact.

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
- Make persisted formats readable across versions: validate while parsing, give
  added fields defaults for older files and tolerate unknown fields from newer
  ones.
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
