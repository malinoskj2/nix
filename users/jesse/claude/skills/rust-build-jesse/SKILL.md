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
size when batching behavior changes.

Discover required checks from the repository's CI, task runner and scripts, then
run the checks relevant to the change. Normally this includes formatting,
Clippy with the repository's warning policy, focused tests and the broader test
target required by CI. Run architectural checks and measured performance or
statement baselines when the affected project defines them. Do not claim a check
passed when its service, fixture or toolchain was unavailable.

Read the final diff for requirement coverage and accidental scope. Report the
behavior changed, checks run and any material limitation.
