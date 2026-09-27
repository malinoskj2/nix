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
   policy, and abstractions own real rules rather than forwarding calls.
6. **Tests and observability:** tests cover the behavior and material failure
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
