---
name: laravel-review-jesse
description: Review Laravel/PHP code for idiomatic design, abstraction, aesthetics and correctness against Jesse's curated rule set, and propose (never apply) better abstractions for new and adjacent code. Use when the user invokes /laravel-review-jesse, asks to review Laravel or PHP changes, or asks how to structure, abstract or clean up Laravel code (controllers, actions, Eloquent, jobs, artisan commands, tests).
argument-hint: "[optional: path, branch, commit range or PR number]"
---

# Laravel review

Target: $ARGUMENTS

## 1. Scope

- No argument: review the working tree plus the current branch against its merge base with the default branch. Otherwise review the given path, range or PR.
- Read every changed PHP file in full, plus the code it calls and is called by. Adjacent existing code is in scope for abstraction proposals (section 4), not for rule nitpicks.
- Read `composer.json`/`composer.lock` for the Laravel and PHP versions and installed packages. Don't suggest APIs newer than the installed version.

## 2. Precedence

1. **The repo's established conventions win.** Before flagging anything, sample the codebase for its existing shape: folder layout, service/repository layering, naming, test framework. Flag deviations from the repo's own convention, not from these rules.
2. **Then Laravel's conventions**: what the docs, skeleton and generators do.
3. **Then the rules below.**

Layering by project kind:

- **Greenfield or modern app**: Actions plus direct Eloquent. Controllers call Eloquent for simple reads and CRUD, and one Action class per business operation (`CreateInvoice::handle()`). No repositories.
- **Legacy app with an established service + repository layer**: follow it. Don't propose migrating to Actions unless asked.
- **Layout**: Laravel defaults (`app/Http/Controllers`, `app/Models`, `app/Actions`, …) unless the repo has its own.
- **Tests**: Pest for new suites. In an existing PHPUnit suite stay with PHPUnit, and flag mixing the two.

## 3. Rules

Each is a check on new or changed code. Pre-existing violations in untouched code aren't findings.

### Architecture

- Controllers only validate, authorize, call something and respond. Business logic, multi-step writes and non-trivial queries move out.
- Collaborators (API clients, services, actions) are injected, never `new`ed inside a class. Value objects and DTOs are exempt.
- Structured non-model data that crosses a boundary is a class, not an associative array: a readonly value object or DTO, or a custom cast when it hydrates from columns.
- Validated input reaches an Action as typed arguments when there are only a few fields, and as a readonly DTO when there are many. Never pass raw arrays into actions.
- `readonly` on DTOs and value objects. Don't add `final` by default.
- Facades are fine anywhere. Don't flag them.

### Routing and HTTP

- Standard CRUD uses `Route::resource()`/`apiResource()`, not hand-written routes.
- Route-model binding (with `scopeBindings()` when nested) instead of `Model::findOrFail($id)`.
- Middleware goes on routes or groups (or `HasMiddleware`), never `$this->middleware()` in a constructor.
- Controllers are singular (`UserController`).
- Non-trivial or repeated validation lives in a FormRequest, and a FormRequest's `authorize()` only delegates to a policy or is omitted.
- Inside a method that receives a `Request`, read the user with `$request->user()`, not `auth()`/`Auth::`.
- Redirect targets taken from input or the referrer are checked against the app's own host.

### Authorization and config

- Model authorization goes through a Policy (`Gate::authorize`, `can` middleware, `$user->can()`). Flag inline `if ($post->user_id !== …) abort(403)`. Gates are only for abilities that aren't about a model.
- `env()` only inside `config/`. Everywhere else use `config()`; `env()` returns null once the config is cached.
- Config files are kebab-case with snake_case keys, and third-party credentials live in `config/services.php`.

### Eloquent

- Don't set `$table`/`$primaryKey` when the convention already matches.
- Relationship methods declare their return type (`HasMany`, `BelongsTo`, …).
- Create related records through the relationship (`$user->posts()->create(…)`), not by setting a foreign key by hand.
- Mass-assigned models declare `$fillable`. Never `$guarded = []` with request data.
- Relations touched in loops, views or resources are eager-loaded up front.
- Per-row counts and existence use `withCount()`/`withExists()`/`loadCount()`, not `->relation->count()` in a loop.
- Filter in SQL (`whereHas`, `withWhereHas`, joins), not with `->filter()` after `get()`. This includes visibility and permission filtering.
- Ask the database, don't load and inspect: `exists()`, `count()`, `value()`, `where(…)->exists()` rather than `get()`/`pluck()` followed by `count`/`contains`.
- No `Model::all()` or unbounded `get()` feeding a loop over a large table. Use `chunkById()` when mutating and `lazy()`/`cursor()` when reading.
- Read-check-write invariants (balance, stock, seats) use `DB::transaction()` with `lockForUpdate()`.
- Observers: guard side effects with `wasChanged()`/`getChanges()`, one concern per observer, and prefer an explicit Action call to hidden observer side effects.

### Queues

- Job shape: `ShouldQueue` plus `Queueable`, a typed, promoted constructor payload, and collaborators injected into `handle()`.
- `handle()` is idempotent: running it twice gives the same end state, so check the current state before transitioning.
- Batched jobs use `Batchable` and return early on `$this->batch()?->cancelled()`.
- Slow or external side effects the response doesn't need (mail, webhooks, third-party APIs) go on the queue.

### PHP

- Closed vocabularies are string-backed enums with PascalCase cases, cast on the model. No magic strings or class-constant lists.
- Native parameter, return and property types everywhere, including `void`. Docblocks only for what PHP can't express (generics, array shapes).
- Constructor property promotion.
- Unhappy path first with an early return. No `else` after a return.
- String interpolation (`"{$x}"`) over `.` concatenation and `sprintf`.
- No `dd`/`dump`/`ray`/`var_dump`/`@dump`.
- No `eval`, `exec`, or `unserialize` on input, and no `md5`/`sha1`/`rand` for secrets. Use `Hash`, `Str::random` or `random_bytes`.
- Comments only for a non-obvious *why*. Flag comments that restate code, section labels, file headers and change history.
- Every value, rule list or constant has one source of truth. Flag the same literal defined in two places.
- Laravel naming: singular models, plural snake_case tables, `{model}_id` foreign keys, alphabetical singular pivot tables.
- Migrations are anonymous classes.

### Tests

- Use the framework's fakes (`Queue::fake`, `Bus::fake`, `Event::fake`, `Mail::fake`, `Notification::fake`, `Http::fake`) plus their assertions, not Mockery on facade internals. Never mock `Request` or `Config`.
- Control time with `freezeTime()`/`travel()`/`travelTo()`, never `sleep`.
- Named variants are factory states, and relations use `for()`/`has()`/`recycle()`, not ad-hoc attribute arrays and manual foreign keys.
- Assert persistence with `assertDatabaseHas`/`assertModelExists`/`assertSoftDeleted`.
- `RefreshDatabase` (or `LazilyRefreshDatabase`) by default.

## 4. Abstraction

Look actively for abstractions in the new code **and the existing code next to it**. The goal is code the Laravel community would call spectacular: declarative, at exactly the right level of abstraction for the problem, and without imperative plumbing.

- **Kill imperative code.** Loops with accumulators, index juggling, flag variables, nested `if` ladders and manual array building should become Collection pipelines (`map`, `filter`, `flatMap`, `groupBy`, `keyBy`, `partition`, `reduce`, `sum`, `pipe`), higher-order messages (`$users->each->notify()`), `match`, query-builder constraints or Eloquent relations. Keep a `foreach` only for an early `break`, heavy side effects or a measured hot path.
- **Reach for a fluent API before writing plumbing** — see the fluency rules below.
- **Right-size it.** Propose an abstraction only when it removes real duplication, names a real concept, or lets a caller read as intent. Don't add an interface with one implementation, a base class with one child, or a "Manager" or "Helper" grab bag.
- **The Laravel toolbox, roughly from lightest to heaviest:**
  - query scope or custom Eloquent builder
  - accessor or custom cast
  - value object or enum with methods
  - Collection macro or a custom collection class
  - `Conditionable`/`Macroable`
  - an Action class
  - a pipeline (`Pipeline::send()->through()`)
  - an event with listeners
  - a job
  - a dedicated service
  - a contract bound in a provider

  Pick the lightest one that fits.

### Fluency

Laravel's fluent surfaces are the default way to express a transformation. Prefer them over nested calls, temporaries and re-assignment.

- **Strings**: `Str::of($x)->trim()->slug()->value()` over nested `str_*` calls. `Stringable` methods (`when`, `whenNotEmpty`, `replaceMatches`, `pipe`, `explode`) instead of intermediate variables.
- **Arrays and lists**: wrap in `collect()` and chain, rather than `array_map(array_filter(…))` nesting or `Arr::` calls stacked on each other.
- **Conditionals inside a chain**: `->when($filter, fn ($q) => …)` / `->unless()` instead of breaking the chain with an `if` and re-assigning the builder.
- **HTTP**: `Http::withToken()->retry(3, 100)->timeout(10)->acceptJson()->post(…)`, and `->throw()`/`->onError()` over manual status checks.
- **Dates, numbers, files**: `Carbon`'s chain (`now()->startOfDay()->addWeekdays(3)`), `Number::` helpers, `Storage::disk()->…` rather than hand-rolled formatting or math.
- **Side effects mid-chain** go in `tap()`; a chain that needs a temporary usually wants `pipe()`.
- **Your own types**: when a caller configures an object step by step, give it a fluent builder — named `with*`/`for*`/verb methods returning `static`, a terminal method that executes (`send()`, `get()`, `dispatch()`), and `Conditionable`/`Macroable` where they fit. Model it on the framework's own builders: a static entry point (`Invoice::for($user)`), immutable or clone-on-write if the object is shared.
- **Don't force it.** No fluent wrapper for a single call site or a single option, no chain so long the intent is lost, and no fluent setter on a DTO that should be `readonly` with a constructor.


**Every abstraction proposal gives 2–3 options the community would accept, with exactly one marked ★ recommended.** Each option gets one line on what it is, one PRO/CON line, and a short code sketch for the ★ option.

## 5. Aesthetics

The code should be beautiful to look at, apart from what it does, as well as having a good API.

- **Symmetry.** Sibling methods have the same shape: parallel names (`publish`/`unpublish`, `attach`/`detach`), the same parameter order, the same return style and the same length. Arms of a `match`, entries in a rules array or routes in a group line up as uniform rows. If one case needs special handling, move it out rather than breaking the pattern.
- **One level of abstraction per method.** A method reads like a table of contents. It either orchestrates named steps or does one low-level thing, never both.
- **Vertical rhythm.** Short, balanced blocks separated by single blank lines, with related lines grouped. No wall of assignments followed by one giant expression.
- **Expressive syntax where it reads better:** `match` over `switch` or if-chains, arrow functions, first-class callables (`strtoupper(...)`), named arguments instead of positional booleans, the nullsafe operator (`?->`) and destructuring.
- **Names carry the meaning,** so no comment is needed. A reader should be able to say what a line does without reading its neighbours.
- **The call site is the product.** Judge an API by how the calling line reads (`$order->ship()->notify()`), not by how its implementation reads.
- **Vertical, not horizontal.** Lines stay short — roughly 100 characters as a ceiling, and well under it in normal code. A long line is a signal to break it up, not to keep typing. Flag horizontal sprawl even when it's syntactically fine.
  - Multi-step chains break one call per line, indented one level, ordered so each line narrows or transforms the previous one. Keep a chain on one line only when it's short enough to read as a sentence.
  - Closures, array literals, argument lists and `match` arms that don't fit go multi-line with a trailing comma, one element per line.
  - Deeply indented code is the same problem from the other side: pull out early returns, named private methods or variables rather than letting nesting push lines right.
  - Don't compensate with cryptic short names. Break the line instead.

## 6. Artisan commands

TODO: reference commands by Jesse go here once their location is known. Match their overall shape.

- **Parse input with Laravel's native APIs.** The `$signature` DSL declares arguments, options, shortcuts, defaults, arrays and descriptions (`{user : The user ID} {--F|force} {--tag=*}`). Read input with `$this->argument()`/`$this->option()`. Use Laravel Prompts (`text`, `select`, `multiselect`, `confirm`, `search`, `spin`, `progress`) and `PromptsForMissingInput` for interactivity, and `Isolatable` against concurrent runs. Never parse `$argv`, split strings by hand or re-implement validation that the signature or prompts already give you.
- **`handle()` is minimal.** It reads as a few named steps (gather input, call an Action or method, report), injects collaborators as parameters, and returns `self::SUCCESS`/`self::FAILURE`. The real work goes to an Action or to small private methods, so the same logic can run from a controller or a job.
- **No noise from long strings.** Long messages, SQL, URLs, JSON and table headers become constants, enum methods, lang entries, config values, heredocs or well-named private methods. The main flow should never be broken up by a wall of string literals.
- **Output goes through `$this->components`** (`info`, `warn`, `error`, `task`, `twoColumnDetail`, `bulletList`), plus `table()`, `withProgressBar()` and prompts' `progress`. No bare `echo`. End by reporting what happened.

## 7. Output

Terse. No praise, no restating the diff, no closing summary.

```
## Findings
path/to/File.php:42  <rule broken>, <concrete fix in one line>
…

## Abstractions
path/to/File.php:10-58  <what's imperative or missing>
  ★ A. <option>. PRO … / CON …
    B. <option>. PRO … / CON …
    C. <option>. PRO … / CON …
  ```php
  // sketch of ★
  ```
```

Order findings by severity: correctness and security first, then design, then aesthetics. If a section is empty, write "none".

## 8. Never edit on your own

This skill only proposes. Don't touch a file, run a formatter or fix anything "while you're there", even when a finding is trivial and even when the fix is obvious.

After the report, walk the user through the findings and abstraction proposals **one at a time**, in severity order, with a separate AskUserQuestion call per suggestion. Never batch several suggestions into one prompt, and never use multi-select.

Each call asks one question about one suggestion:

- `question` makes the whole case for that single change: what is wrong, the file and line, why it matters (the bug it causes or the rule it breaks), what the fix is, and what it costs. Several sentences belong here — this is what the user reads instead of scrolling back to the report.
- `header` names the rule or concept in at most 12 characters (`Injection`, `N+1`, `Locking`, `Enum`).
- `options` for a finding are `Apply` (marked ★ when worth taking) and `Skip`. For an abstraction they are the report's options, ★ recommended first, then `Skip`, with each option's PRO/CON as its description.
- `preview` carries the code sketch, so options are compared by shape rather than by label.

Prefix each question with its position (`3 of 11`) so the user can see how far there is to go, and take `stop`, `skip the rest` or `apply everything` as an instruction to stop prompting.

Apply each accepted change before asking the next question, and report it in one line. Anything skipped or unanswered stays unapplied.
