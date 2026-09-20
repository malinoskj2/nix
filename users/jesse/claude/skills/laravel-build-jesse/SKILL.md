---
name: laravel-build-jesse
description: Implement Laravel/PHP features, fixes and requested refactors using Jesse's curated architecture, abstraction and aesthetics preferences. Use when the user invokes /laravel-build-jesse or asks to build or change Laravel/PHP code. For review-only requests, use laravel-review-jesse instead.
---

# Laravel build

Task: $ARGUMENTS

Build the requested behavior, including the routes, persistence, authorization,
jobs and tests it needs. Apply changes and verify them. This is the implementation
counterpart to `laravel-review-jesse`; its coding preferences are included below
so the build workflow stands on its own.

## 1. Establish the task

- Use the arguments and conversation to identify the requested behavior and its
  acceptance criteria. If neither gives a task, ask what to build before editing.
- Read the repository instructions, working-tree diff and relevant files in full,
  including callers, collaborators and nearby tests. Preserve unrelated work.
- Read `composer.json` and `composer.lock` for the PHP/Laravel versions, packages
  and scripts. Use APIs supported by those versions and the repo's existing tools.
- Trace the affected request, command or job through to its stored state and
  external effects. Account for validation, authorization and failure paths.
- Resolve routine implementation choices and proceed. Ask only when missing
  behavior or a consequential tradeoff cannot be inferred from the code or task.

## 2. Precedence

Explicit task requirements come first. Otherwise:

1. Follow the repo's established conventions: layout, layering, naming and tests.
2. Follow Laravel's conventions: its framework APIs, skeleton and generators.
3. Apply the preferences below to the code being built or changed.

- **Greenfield or modern app:** Actions plus direct Eloquent. Controllers may use
  Eloquent for simple reads and CRUD; use one Action per business operation
  (`CreateInvoice::handle()`). Don't introduce repositories.
- **Legacy service/repository app:** follow the existing layers. Don't migrate
  its architecture as part of an unrelated feature.
- **Layout:** Laravel defaults (`app/Http/Controllers`, `app/Models`,
  `app/Actions`, etc.) unless the repo establishes another layout.
- **Tests:** Pest for new suites; keep PHPUnit in an existing PHPUnit suite.

## 3. Build with these rules

### Architecture

- Controllers validate, authorize, delegate and respond. Move business logic,
  multi-step writes and non-trivial queries into the appropriate collaborator.
- Inject collaborators such as clients, services and actions; don't instantiate
  them inside a class. Value objects and DTOs may be constructed directly.
- Structured non-model data crossing a boundary uses a readonly value object or
  DTO; use a custom cast for structured data hydrated from model columns.
- Actions receive validated input as typed arguments for a few fields, or a
  readonly DTO for many. Don't pass raw arrays into actions.
- Use `readonly` for DTOs and value objects. Don't add `final` by default.
- Facades are fine anywhere.

### Routing, authorization and config

- Use `Route::resource()`/`apiResource()` for standard CRUD and limit the exposed
  actions to those needed. Controllers have singular names (`UserController`).
- Use route-model binding, with `scopeBindings()` for nested ownership, rather
  than fetching bound models with `findOrFail()`.
- Put middleware on routes/groups or use `HasMiddleware` when supported; don't
  call `$this->middleware()` in a constructor.
- Put non-trivial or repeated validation in a FormRequest. Its `authorize()`
  delegates to a policy or is omitted when authorization happens elsewhere.
- Authorize model operations through policies (`Gate::authorize`, `can`
  middleware, `$user->can()`). Reserve gates for non-model abilities.
- In methods receiving a Request, use `$request->user()`.
- Validate input/referrer redirect targets against the app's own host.
- Use `env()` only inside `config/`; use `config()` elsewhere for cache safety.
- Config filenames are kebab-case, keys snake_case. Third-party credentials
  belong in `config/services.php`.

### Eloquent and persistence

- Omit `$table`/`$primaryKey` when the conventions already match. Declare
  relationship return types (`HasMany`, `BelongsTo`, etc.).
- Create related records through relationships, rather than assigning foreign
  keys manually. Mass-assigned models declare `$fillable`; never combine
  `$guarded = []` with request data.
- Eager-load relations used in loops, views and resources. Use `withCount()`,
  `withExists()` or `loadCount()` for per-row aggregates.
- Filter in SQL, including visibility and permissions; don't fetch everything
  and then filter a Collection. Ask the database with `exists()`, `count()` or
  `value()` rather than loading records merely to inspect them.
- Avoid unbounded `all()`/`get()` loops over large tables. Use `chunkById()` when
  mutating and `lazy()`/`cursor()` when reading, as appropriate to the query.
- Protect read-check-write invariants such as stock, seats and balances with
  `DB::transaction()` and `lockForUpdate()` on the relevant rows.
- Prefer explicit Action calls to hidden observer side effects. When observers
  fit, keep one concern per observer and guard effects with `wasChanged()` or
  `getChanges()`.
- Use singular model names, plural snake_case tables, `{model}_id` foreign keys
  and alphabetical singular pivot tables. Migrations use anonymous classes.
- Consider existing rows when changing schemas; preserve their data unless the
  task requires otherwise. Running migrations against shared environments is a
  separate operation from writing and testing them.

### Queues and external effects

- Jobs use `ShouldQueue`, `Queueable`, typed promoted constructor payloads and
  collaborators injected into `handle()`.
- Make `handle()` idempotent: retries must not duplicate state transitions or
  external effects. Use state checks, atomic claims or provider idempotency keys
  as appropriate; a local state check alone does not protect a remote call.
- Batched jobs use `Batchable` and return early when
  `$this->batch()?->cancelled()`.
- Queue slow or external side effects the response doesn't need, such as mail,
  webhooks and third-party API calls. Dispatch after commit when a job depends
  on data written by the current transaction.

### PHP

- Use string-backed enums with PascalCase cases for closed vocabularies, and
  cast them on models. Avoid magic strings and class-constant lists.
- Use native parameter, return and property types, including `void`, plus
  constructor property promotion. Docblocks cover what PHP cannot express,
  such as generics and array shapes.
- Handle the unhappy path first with early returns; no `else` after a return.
- Prefer string interpolation over concatenation and `sprintf`.
- Leave no debugging calls (`dd`, `dump`, `ray`, `var_dump`, `@dump`).
- Never pass input to `eval`, `exec` or `unserialize`. Use `Hash`, `Str::random`
  or `random_bytes` as appropriate for passwords and secrets.
- Comments explain a non-obvious why. Omit comments that restate code, section
  labels, file headers and change history.
- Keep each domain value, rule list and constant in one source of truth.

## 4. Choose and implement abstractions

Aim for code a Laravel developer would consider beautifully designed: expressive
call sites, cohesive concepts and implementation details held at the right level.
Choose abstractions for how clearly they express the problem. Reducing duplication
is one benefit; naming a business operation, protecting an invariant or separating
policy from mechanics can justify an abstraction with a single caller.

Actively design the API and implement it within the task. Don't require an options
report or approval for each routine design decision. Consider adjacent code for
concepts worth reusing or extending, while keeping unrelated cleanup outside the
change.

- **Design from the call site.** Write the business flow in the language of the
  domain, then give its steps coherent implementations. A reader should understand
  the operation without mentally executing query details, array transformations
  or state bookkeeping.
- **Extract meaningful concepts early.** A named scope for eligibility, a value
  object for a date range or an Action for reserving stock can earn its place on
  first use. Don't wait for duplication when the concept already has a clear
  responsibility. Names must convey domain meaning beyond `process` or `handleData`.
- **Keep orchestration at one level.** If a method mixes business decisions with
  lower-level mechanics, introduce named operations or types that let the flow
  read consistently. Moving an opaque block into an equally opaque helper is not
  enough; the resulting boundary should make both sides easier to understand.
- Prefer Collection pipelines, higher-order messages, `match`, query constraints
  and relationships over accumulators, index juggling, flag variables, nested
  conditionals and manual array building. Keep `foreach` for early breaks,
  substantial side effects or measured hot paths. Give a substantial pipeline a
  domain name when that makes the caller clearer.
- **Choose the Laravel abstraction that fits the responsibility.** Use scopes or
  custom builders for query vocabulary, casts/value objects/enums for domain
  values, Actions for business operations, and collections, pipelines, events,
  jobs or services for their respective roles. Choose the simplest implementation
  that fully expresses the concept; fewer classes or lines is not the objective.
- **Make every layer earn its place.** It should provide meaningful vocabulary,
  encapsulate rules or establish a useful boundary. Avoid pass-through layers,
  speculative extension points and Manager/Helper grab bags. An interface or base
  class needs a concrete boundary or shared contract to express.
- **Review the shape before finishing.** Read the main call sites and ask whether
  they tell the business story, whether each type owns a coherent responsibility,
  and whether callers still know details that belong inside an abstraction. Refine
  code that works but remains procedural or awkward to use.

### Fluency

- Strings: `Str::of($value)->trim()->slug()->value()` and Stringable methods
  instead of nested calls and intermediate reassignment.
- Lists: `collect()` pipelines instead of nested `array_map`/`array_filter`
  or stacked `Arr::` calls; keep database filtering in SQL.
- Conditions in chains: `when()`/`unless()`; distinguish an absent filter from
  meaningful falsey input such as `0`.
- HTTP: configure authentication, timeouts, retry behavior and error handling
  through `Http`'s fluent API. Retry writes only when safe to repeat.
- Dates, numbers and files: Carbon, `Number` and `Storage` APIs rather than
  hand-rolled formatting or filesystem plumbing.
- Use `tap()` for side effects within a chain and `pipe()` for transformations
  that would otherwise need an intermediate variable.
- For genuine multi-step configuration, give custom types named fluent methods
  returning `static` and a terminal operation such as `send()` or `dispatch()`.
  Use immutable/clone-on-write builders when shared. A single caller is sufficient
  when the fluent vocabulary makes a substantial operation clearer. Each method
  should express a meaningful choice or step; avoid ceremonial wrappers, chains
  that obscure intent and setters on readonly DTOs.

## 5. Aesthetics

- Keep sibling methods symmetrical: names, parameter order, return style and
  overall shape. Keep match arms, validation rules and route groups uniform.
- Keep one level of abstraction per method: orchestrate named steps or perform
  one low-level operation. Judge the API by how its call sites read.
- Use short, balanced blocks with single blank lines between related groups.
  Prefer names that explain the code without comments.
- Use `match`, arrow functions, first-class callables, named arguments for
  positional booleans, nullsafe access and destructuring when clearer.
- Keep lines roughly under 100 characters unless the repo specifies otherwise.
  Break multi-step chains one call per line; expand long closures, arrays,
  argument lists and match arms with trailing commas. Reduce nesting with early
  returns or named steps; don't shorten meaningful names just to fit a line.

## 6. Artisan commands

- Follow nearby command examples. Declare inputs in `$signature` and read them
  with `argument()`/`option()`; don't parse `$argv` or hand-split input.
- Use Laravel Prompts and `PromptsForMissingInput` for interactivity, and
  `Isolatable` when concurrent runs must be prevented, subject to version support.
- Keep `handle()` to gathering input, calling an Action or small methods and
  reporting results. Inject collaborators into it and return
  `self::SUCCESS`/`self::FAILURE`.
- Move long messages, SQL, URLs, JSON and headers out of the main flow into
  appropriate constants, enum methods, translations, config, heredocs or named
  methods. Keep business logic reusable from controllers and jobs.
- Use `$this->components`, `table()`, `withProgressBar()` and prompts' `progress`
  for output. No bare `echo`. End by reporting what happened.

## 7. Verify and finish

- Add or update tests for changed behavior and meaningful failure paths. Cover
  authorization, validation, persistence and retry/concurrency behavior where
  relevant; don't add tests that merely mirror implementation details.
- Use framework fakes and their assertions for queues, buses, events, mail,
  notifications and HTTP. Don't mock facade internals, Request or Config.
- Control time with `freezeTime()`/`travel()`/`travelTo()`, never `sleep`.
- Use named factory states and `for()`/`has()`/`recycle()` for relationships.
  Assert persistence with `assertDatabaseHas`, `assertModelExists` and
  `assertSoftDeleted`. Use `RefreshDatabase`/`LazilyRefreshDatabase` by default
  for database tests against an isolated test database.
- Run the affected tests and the repository's applicable formatter/static
  analysis checks. Keep formatting scoped to the change. Broaden verification
  when shared behavior or a failing check warrants it.
- Inspect the final diff against the requested behavior and the rules above.
  Fix issues introduced by the implementation and rerun the relevant checks.
- Finish with a terse account of what changed, verification results and any
  unresolved limitation. Identify checks that could not run. Mention required
  migrations or worker restarts without claiming they have been applied.
