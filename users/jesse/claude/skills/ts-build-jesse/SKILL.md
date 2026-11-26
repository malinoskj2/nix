---
name: ts-build-jesse
description: Implement or refactor TypeScript code using the active repository's requirements, domain rules and verification workflow. Use for requested TypeScript code changes; use ts-review-jesse for review-only work and vue-build-jesse for Vue components.
---

# TypeScript build

Use the task from `$ARGUMENTS` when present; otherwise use the request or
delegation. Complete the requested implementation and verification. Explicit
requirements and repository instructions take precedence over this guidance.

## Establish the change

- Inspect the working tree and preserve unrelated changes.
- Read `package.json`, the lockfile, every `tsconfig*.json` the change touches,
  the owning module, relevant callers and nearby tests. Use the package manager,
  runtime, module system and dependency versions the repository already selects.
- Read only the applicable sections of project standards, architecture documents
  and decision records. Do not preload an entire documentation stack for a small
  change.
- Translate the request into observable behavior, including material failure,
  cancellation, retry and compatibility behavior. Resolve routine choices from
  repository evidence; ask only when an unresolved product choice changes the
  outcome.

## Mechanized rules

Run `ts-lints` at the project root before you start, to know the baseline, and
again before finishing; fix its findings in the code you changed. It lints any
TypeScript or Vue project without editing it, ignoring the project's own ESLint
config: type-aware rules for files a `tsconfig.json` covers once dependencies
are installed, syntax rules for the rest, then a strict type check per tsconfig
(`tsc`, or `vue-tsc` in a Vue project). Exit status 0 is clean, 1 findings, 2 a
tool failure; `--json` gives a machine-readable report, `--no-types` and
`--no-tsc` skip the slow passes. A project's explicit compiler option wins over
ours and the report lists it.

`ts-lints --paths` prints the source of truth (`pkgs/ts-lints/` in the Nix
repository):

- `config.mjs`: built-in rule levels from ESLint, typescript-eslint
  (`strictTypeChecked` and `stylisticTypeChecked` plus off-preset rules),
  eslint-plugin-vue, unicorn, sonarjs, import-x, eslint-comments, regexp,
  vuejs-accessibility, pinia and vitest.
- `plugin/rules/`: the custom `jesse/*` rules.
- `tsconfig.strict.json`: the compiler flags and `vueCompilerOptions` the type
  check adds.

Rules below that name a lint are enforced there. What needs judgment is in
`checklist.md` of `ts-review-jesse`; read it before finishing. Suppress a
justified finding with `// eslint-disable-next-line <rule> -- <reason>`; a
suppression needs a reason and is an error once it no longer applies. If
`ts-lints` is unavailable, report that gap and check the rules by hand.

## Project structure

Organize by feature or domain responsibility, not by kind. A module owns its
types, errors, constants and helpers and exports a small API.

```text
project/
├── package.json
├── tsconfig.json        # strict; references app and node configs when split
├── src/
│   ├── main.ts          # Configuration, wiring, startup, error reporting
│   ├── config.ts        # Parsed environment and settings
│   ├── billing/
│   │   ├── invoice.ts   # Domain types and rules
│   │   ├── invoice.test.ts
│   │   ├── store.ts     # Persistence adapter
│   │   └── errors.ts    # Typed errors for this feature
│   └── http/
│       └── server.ts    # Transport adapter over the features
└── tests/
    └── workflow.test.ts # End-to-end behavior through public entry points
```

- Catch-all modules and directories (`utils`, `helpers`, `common`, `misc`,
  `constants`): `jesse/no-catch-all-module`.
- Re-export-only `index.ts` outside a package entry: `jesse/no-barrel-file`.
  Import from the defining module.
- Named exports only, except framework and config files that require a default:
  `import-x/no-default-export`.
- Type-only imports and exports are explicit: `verbatimModuleSyntax`,
  `@typescript-eslint/consistent-type-imports` and `consistent-type-exports`.
- Keep business logic out of entry points. Read `process.env` and
  `import.meta.env` in one config module that parses them, not across features.
- Keep dependencies between features acyclic and domain modules free of
  transport, UI and storage imports.
- Apply this within the requested scope; do not turn a focused change into an
  unrelated reorganization.

## Module ownership

Avoid heavily nested logic (`max-depth`, `max-nested-callbacks` and
`sonarjs/cognitive-complexity` flag the worst): use guard clauses where they
clarify control flow, split work at cohesive responsibility boundaries, and
consider whether deep nesting signals a missing domain abstraction that should
own the rules or state.

- **Separate decisions from effects.** Policy takes observations and returns
  typed decisions, testable without I/O.
- **Align state with resource lifetimes.** A connection owns its parser,
  buffers and timers; reconnects reset other cached observations explicitly.
- **No shared mutable module state** on servers or in libraries; pass state
  through owners. `import-x/no-mutable-exports` covers exported bindings.
- More than four parameters (`max-params`) call for an options object.

## Conditional checks

Every conditional should select meaningful behavior, enforce an invariant or
handle a possible failure. Avoid checks already guaranteed by a parser,
narrowed type, preceding branch or ownership unless that guarantee can change
before use (`@typescript-eslint/no-unnecessary-condition` finds the provable
ones). Trace callers and state transitions before declaring a check redundant;
include error, cancellation and shutdown paths. Preserve input validation,
capacity checks, deadlines and cleanup guards. Never replace a necessary check
with `!` or an assertion.

## Fixed strings

Name long fixed text and repeated semantic identifiers (storage keys, event
names, header names, protocol values) as `const` values beside their owning
feature. A closed set of values is an `as const` object or array with its union
type derived from it. Keep obvious one-off labels and error messages inline.
Keep changeable configuration separate from fixed text, and avoid a global
constants module.

## Dependency choices

Use the repository's package manager and keep its lockfile authoritative. Before
writing code for a problem that is not specific to the project, such as a
standard format, protocol, schema validation, date handling or concurrency
limit, look for an established package already in the dependency graph or the
platform (Node, the DOM, Web APIs) and use it. Established means wide adoption,
active maintenance and a recognized maintainer. Do not add a package with little
adoption; if one looks unusually good, mention it with evidence for approval
and proceed without it. Check its maintenance, ESM support, types and runtime
compatibility first. Add only what the task needs, as exact or caret versions
following the repository's convention, and never migrate unrelated existing
dependencies.

## Types

- The type check adds the flags in `tsconfig.strict.json`: `strict`,
  `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
  `noPropertyAccessFromIndexSignature`, `noImplicitOverride`,
  `noImplicitReturns`, `noFallthroughCasesInSwitch`, `verbatimModuleSyntax`,
  `erasableSyntaxOnly` and `noUncheckedSideEffectImports`. Write code that
  passes them even where the project's tsconfig is looser.
- Model closed sets of states and outcomes as discriminated unions whose
  members carry only the data valid in that state, instead of a status field
  plus optional fields. Return an outcome union from an operation with several
  meaningful results instead of a boolean or sentinel.
- Switch over a union exhaustively without a `default` that hides new members:
  `@typescript-eslint/switch-exhaustiveness-check`.
- No `enum`, `namespace` or parameter properties (`erasableSyntaxOnly`); use
  string-literal unions and `as const` objects.
- A boolean literal argument to a project function (`jesse/no-boolean-literal-argument`)
  calls for a string-literal union or an options object. Setters (`setX`,
  `withX`) are exempt.
- No `any` (`@typescript-eslint/no-explicit-any`, `no-unsafe-*`). Use `unknown`
  at trust boundaries and narrow it.
- Assertions only where the compiler cannot know a fact you can state:
  `@typescript-eslint/no-unsafe-type-assertion`, `jesse/no-double-assertion`,
  `no-non-null-assertion`. Prefer a type guard, `satisfies` or a parser.
- Exported functions declare parameter and return types
  (`@typescript-eslint/explicit-module-boundary-types`); let inference type
  locals.
- Give identifiers that must not mix (user IDs and order IDs, cents and
  dollars) branded types minted only by the parser or constructor that
  validates them.
- Mark data `readonly` where mutation is not intended
  (`@typescript-eslint/prefer-readonly` covers class members).
- Use `interface` for object shapes and `type` for unions and computed types
  (`@typescript-eslint/consistent-type-definitions`).

## Boundaries and validation

Parse external data at the boundary where it enters: HTTP bodies, `fetch`
responses, `JSON.parse`, storage, environment, messages and files. Use the
repository's schema library (Zod, Valibot, ArkType or another Standard Schema
implementation; Zod when choosing for a new project) and derive the static type
from the schema instead of writing it twice. Asserting a type onto parsed JSON
is a finding: `jesse/no-unvalidated-parse`. Parse once; pass the validated type
inward and do not re-validate it.

Keep persisted and wire formats readable across versions: reject invalid
values, default fields that older writers omitted and tolerate unknown fields
from newer ones. Store money and other exact quantities as integers or decimal
strings, never binary floating point, with units or currency where they matter.

## Error handling

- Throw only `Error` instances (`@typescript-eslint/only-throw-error`,
  `prefer-promise-reject-errors`, `unicorn/throw-new-error`).
- Define typed error classes per feature, extending `Error` with a literal
  `name` or `code` callers can branch on. Rethrow with `{ cause }`
  (`preserve-caught-error`); the message names the failed step without
  repeating the cause.
- Never branch on message text: `jesse/no-error-message-matching`.
- Return a discriminated result for expected failures the caller must handle,
  such as validation outcomes; throw for bugs and unrecoverable failures. Keep
  one style per layer, and do not add a new functional-error framework without
  the project's buy-in.
- Catch where you can recover, add context or translate at a boundary. A catch
  that drops the error and returns an empty value is a finding:
  `jesse/no-swallowed-catch`. Log an error once, where it is handled.
- Catch variables are `unknown` (`useUnknownInCatchVariables`,
  `use-unknown-in-catch-callback-variable`); narrow before use.

## Async

- Every promise is awaited, returned or explicitly handed to an owner:
  `@typescript-eslint/no-floating-promises`, `no-misused-promises`,
  `promise-function-async`, `return-await`.
- Pass an `AbortSignal` through every chain of network or long-running work and
  give each external call a deadline (`AbortSignal.timeout`). Cancellation is
  not an error to report.
- Bound concurrency, retries, queues and result sizes. `Promise.all` over a
  `.map()` of unknown size is flagged (`jesse/no-unbounded-promise-all`); use a
  limiter.
- No blocking `*Sync` calls inside async functions: `jesse/no-sync-call-in-async`.
- Every timer, listener, subscription and background loop has an owner that
  stops it, ideally through an `AbortController` or `using`.
- Put related writes and read-check-write invariants in one transaction; keep
  network calls out of database transactions.

## Comments and formatting

Format with the repository's formatter (Prettier, Biome, oxfmt or dprint);
formatting rules are off in the lint set. Comment only a non-obvious why. No
file header or module summary comment (`jesse/no-file-header-comment`), no
commented-out code (`sonarjs/no-commented-code`), no section labels or comments
restating the next line.

Within functions, use a single blank line to separate meaningful logical steps
(validation, preparation, effects, result), keeping tightly related statements
together. Put one empty line between top-level declarations and between class
members, except within a compact group of imports or related constants.

## Lints

Follow the repository's lint configuration. When establishing one, use ESLint
flat config with typescript-eslint `strictTypeChecked` and
`stylisticTypeChecked` and the levels in `config.mjs`, a tsconfig with the
flags in `tsconfig.strict.json`, and CI that runs the type check, ESLint with
`--max-warnings 0` and the tests. Do not impose this on an existing project as
unrelated work.

## Implement

Make the smallest coherent change that delivers the behavior through its real
entry point, domain logic and persistence or external boundary.

- Convert external representations into domain types at adapters, before they
  spread through the application.
- Preserve missing, stale, unavailable and approximate states when they are
  meaningful; never invent a value to simplify a type.
- For CLIs, use the repository's argument parser; when choosing one, prefer
  `node:util` `parseArgs` for small tools and Commander for full-featured
  CLIs. Reject invalid input before starting databases, network clients or
  workers.
- Prefer the repository's established libraries and module ownership. Add an
  interface only for a real capability boundary, caller choice or test seam.

## Verify

Test observable behavior and the material failures introduced or changed, with
the repository's test runner (Vitest, `node:test` or Jest). Use focused unit
tests for domain logic and the real integration setup for database, process or
protocol semantics. Exercise a batch beyond its chunk size when batching
changes. Test CLI parsing directly rather than spawning the program, unless
exit status or output is the contract.

Discover required checks from CI, `package.json` scripts and the task runner;
normally the type check, lint, formatting and the tests. Run `ts-lints`. Do not
claim a check passed when its service, fixture or toolchain was unavailable.

Read the final diff for requirement coverage and accidental scope. Report the
behavior changed, checks run and any material limitation.
