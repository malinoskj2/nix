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
- Prefer `thiserror` for domain, adapter and reusable-library errors that callers
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
