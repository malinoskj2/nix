---
name: ts-review-jesse
description: Review TypeScript changes for requirement coverage, correctness, type design, failure safety, bounded operation and module design. Use for review-only requests and report findings without editing; use vue-review-jesse as well when the change touches Vue components.
---

# TypeScript review

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
- Read the owning modules and tests, `package.json`, the tsconfigs that cover
  the change, and only the relevant sections of project standards and decision
  records. Judge the change against those sources rather than its own
  description.

Trace changed inputs through parsing, domain conversion, persistence or external
effects, derived state and exposed results. Use focused, non-mutating checks when
they can confirm or reject a concrete concern; state when verification could not
be run.

## Mechanized rules

Run `ts-lints` (`--json` for a machine-readable report) at the project root
first. It applies the shared ESLint rules, the custom `jesse/*` plugin and a
strict type check to any TypeScript or Vue project without editing it,
ignoring the project's own ESLint config. Type-aware rules and the type check
need the project's dependencies installed; the report's notices say when a
tsconfig was linted without types for lack of `node_modules`. Exit status 0 is
clean, 1 findings, 2 a tool failure.

Report findings in the reviewed scope with their rule names, separating ones
the change introduced from ones it only touches. Report project overrides that
switch off a compiler flag the change relies on. `ts-lints --paths` prints the
source of truth: `config.mjs` (built-in rule levels), `plugin/rules/` (custom
rules) and `tsconfig.strict.json` (compiler flags), in `pkgs/ts-lints/` of the
Nix repository. Do not re-review what a lint enforces; review what it cannot
see, using [`checklist.md`](checklist.md). If `ts-lints` is unavailable or
fails, report that gap and check the mechanized rules by hand.

## Review priorities

1. **Requirement coverage:** requested behavior exists end to end, including
   material errors, cancellation, retries, restarts and compatibility.
2. **Correctness and semantics:** types preserve meaningful distinctions and
   units; exact values stay exact; absence is not silently converted to a
   default; external input is parsed at its boundary (`jesse/no-unvalidated-parse`)
   and cannot crash the process; persisted formats load data written by older
   and newer versions.
3. **Type design:** variant state is a discriminated union, switches over it are
   exhaustive (`switch-exhaustiveness-check`), and there are no escape hatches
   (`no-explicit-any`, `no-unsafe-*`, `no-unsafe-type-assertion`,
   `jesse/no-double-assertion`, `no-non-null-assertion`). Remaining assertions,
   guards and brands are justified (checklist).
4. **Failure safety:** atomic work commits completely or not at all; partial
   input is not recorded as complete; retries are safe; cancellation and errors
   leave valid state. Errors are typed, keep their `cause`
   (`preserve-caught-error`), are never matched by message
   (`jesse/no-error-message-matching`) and are not swallowed
   (`jesse/no-swallowed-catch`).
5. **Bounded operation:** request bodies, deadlines, retries, fan-out
   (`jesse/no-unbounded-promise-all`), queues, pagination and result sizes have
   defensible limits; every promise has an owner (`no-floating-promises`,
   `no-misused-promises`); async code does not block
   (`jesse/no-sync-call-in-async`); timers, listeners and subscriptions are
   released.
6. **Module design:** features own their types, errors and helpers; no
   catch-all modules (`jesse/no-catch-all-module`) or barrels
   (`jesse/no-barrel-file`); layers point one way; abstractions own real rules
   rather than forwarding calls. Hand-written code that duplicates an
   established package's job, and a newly added package with little adoption or
   maintenance, are findings.
7. **Tests and observability:** tests cover the behavior and material failure
   paths at the right boundary; diagnostics are actionable and do not expose
   secrets or tokens.

Report states encoded as flags or optional fields that a union would rule out,
boolean parameters that a union or options object would name
(`jesse/no-boolean-literal-argument` finds call sites), and comments that
restate code or describe the file (`jesse/no-file-header-comment`) as findings.
Do not demand unrelated restructuring.

## Report

List findings first, ordered by impact. For each finding include the file and
line, triggering scenario, consequence, evidence and concrete correction, and
the rule name when a lint reported it. Keep verified defects, requirement gaps,
questions and residual risks distinct. Do not report stylistic preference as a
defect when several idiomatic designs meet the repository's standards.

If nothing material is wrong, say so and name the checks performed and remaining
risks.
