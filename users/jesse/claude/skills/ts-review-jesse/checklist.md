# TypeScript review checklist

These rules need judgment, so no lint enforces them. `ts-lints` covers the
mechanical rules; read its report first and do not repeat its findings here.

## Types

- Variant state is a discriminated union, not a status field plus optional
  fields. Impossible combinations cannot be built.
- An operation with several meaningful outcomes returns a union of them, not a
  boolean, sentinel or exception used as control flow.
- Identifiers and quantities that must not mix carry brands, and only the
  parser or constructor that validates them mints the brand.
- Each remaining assertion, type guard and assertion function states a fact the
  compiler cannot know, is as narrow as possible and is tested.
- `satisfies`, an annotation and `as const` are each chosen for what they do:
  checking a literal, fixing a declared type, or keeping literal types.
- Exported types do not leak implementation detail; generics earn their
  parameters; conditional and mapped types stay readable.
- Parameters and data are `readonly` where mutation is not intended, and shared
  arrays are not sorted or reversed in place.

## Boundaries

- Every trust boundary is identified and parsed exactly once, with the static
  type derived from the schema rather than written beside it.
- Whether unknown fields are stripped, kept or rejected is a deliberate choice
  that matches the format's compatibility needs.
- Validated data is not re-validated deeper inside, and unvalidated data does
  not reach domain code by another path.
- Environment and configuration are parsed in one place, with defaults and
  failures that make sense at startup.

## Errors

- Expected failures that callers must handle are typed in the signature;
  bugs and unrecoverable failures throw. The style is consistent within a
  layer.
- Catches sit where the code can recover, add context or translate at a
  boundary, and each error is logged once.
- Error classes expose what callers branch on (`name`, `code`, fields), and
  messages name the failed step without repeating the cause.
- Cancellation is distinguished from failure and is not reported as an error.

## Async and resources

- Cancellation, deadlines and retries are bounded and propagated end to end
  through `AbortSignal`; when one `Promise.all` sibling fails, the others are
  aborted when they would otherwise keep working.
- Concurrency is bounded where the input size is not; sequential awaits in a
  loop are intended (ordering or back-pressure) rather than accidental.
- Listeners, timers, subscriptions, streams and child processes are tied to an
  owner that releases them on every path.
- State that outlives a request is owned explicitly; servers and libraries do
  not keep shared mutable module state.

## Structure

- Modules are organized by feature or domain responsibility, expose a small
  API and point their dependencies one way (domain does not import transport,
  UI or storage).
- A new abstraction owns a real rule, capability boundary or test seam rather
  than forwarding calls.
- Conditionals select behavior, enforce an invariant or handle a failure;
  checks already guaranteed by a parser, narrowed type or earlier branch are
  removed, while validation, capacity, deadline and cleanup guards stay.
- New dependencies are established, maintained and necessary; hand-written
  code does not duplicate one already in the graph.

## Comments and formatting

- Comments explain a non-obvious why. No section labels, comments restating
  the next line, cross-reference pointers or change history.
- Blank lines separate logical steps within functions, and one empty line
  separates top-level declarations and class members.

## Tests

- Tests cover the behavior and the material failure paths at the boundary that
  owns them, with assertions on outcomes rather than implementation detail.
- Batching, pagination and limits are exercised past their boundaries.
