# Vue review checklist

These rules need judgment, so no lint enforces them. Read the `ts-lints` report
first and do not repeat its findings; `ts-review-jesse`'s checklist still
applies to the TypeScript.

## State

- State lives at the narrowest scope that works: component, composable,
  `provide`/`inject`, then a store.
- Derived values are `computed`, not refs kept in sync by watchers.
- `ref`, `reactive`, `shallowRef` and `markRaw` match the data's shape, size
  and ownership.
- Stores own their mutations as the project's convention requires, do not read
  each other circularly at setup time and do not reimplement a server cache the
  query library already provides.

## Watchers and effects

- `watch`, `watchEffect` and `computed` are each used for what they are for;
  `immediate`, `once`, `deep` and `flush` are set deliberately.
- Async effects cancel stale work (`onWatcherCleanup`, `AbortController`) and
  ignore results that arrive after their source changed.
- `watchEffect` does not read reactive state only after an `await`, where it is
  no longer tracked.

## Composables

- Each composable is cohesive, accepts `MaybeRefOrGetter` inputs, returns refs,
  releases listeners, timers and observers in `onScopeDispose`, and hides no
  module-level shared state unless it is deliberately a singleton.
- SSR-rendered apps do not touch `window` or `document` outside lifecycle hooks.

## Components

- Props are minimal and typed; events are named for intent (`select`, not
  `click`); slots replace configuration props for layout variations.
- Generic components (`generic="T"`) are used where item types vary.
- `defineExpose` exposes only an intended imperative API.
- A component that fetches data, owns form state and renders a list at once
  splits along those responsibilities.

## Routing

- A component reused for new params reloads its data.
- Navigation failures are handled where they matter, and scroll and focus are
  managed on route change.
- Auth and permission checks live in guards or the server, not only in hidden
  buttons.

## Templates and safety

- Template expressions stay simple; logic lives in script.
- `v-html` sources and bound URLs are trusted or sanitized.
- User-visible text follows the project's i18n setup when it has one.

## Accessibility

- Native interactive elements are used before ARIA roles.
- Dialogs trap and restore focus; navigation moves focus to the new content.
- Async status and errors are announced through a live region.
- Every action works by keyboard, and contrast and focus styles stay visible.

## Performance

- `v-memo`, `v-once`, `<KeepAlive>`, virtualization and async components are
  justified by a measured need, and `<KeepAlive>` sets `max`.
- Hot lists receive stable props and avoid per-item watchers.

## Tests

- Components are tested through their rendered DOM and emitted events, not
  internal state; stores and composables are tested in isolation; end-to-end
  tests cover flows across routes and the network.
