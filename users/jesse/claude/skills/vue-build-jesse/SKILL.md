---
name: vue-build-jesse
description: Implement or refactor Vue 3 components, composables, stores and routes in TypeScript using the active repository's requirements and verification workflow. Use for requested Vue code changes together with ts-build-jesse; use vue-review-jesse for review-only work.
---

# Vue build

Use the task from `$ARGUMENTS` when present; otherwise use the request or
delegation. Explicit requirements and repository instructions take precedence
over this guidance.

Follow `ts-build-jesse` for everything that is plain TypeScript: establishing
the change, module ownership, types, boundaries, errors, async work, comments,
dependencies and verification. This skill adds what is specific to Vue. Target
Vue 3.5 APIs; treat Vapor mode and other pre-release features as unavailable
unless the repository already uses them.

## Mechanized rules

`ts-lints` detects Vue (a `.vue` file or a `vue` dependency) and adds, in
`config.mjs`: eslint-plugin-vue's `flat/recommended-error` plus the
uncategorized rules listed there, eslint-plugin-vuejs-accessibility's
recommended set, eslint-plugin-pinia's recommended set and the `jesse/vue-*`
rules in `plugin/rules/`. Its type check runs `vue-tsc` with
`vueCompilerOptions.strictTemplates`, so unknown components, props, events and
directives and wrong `v-model` types are compile errors; unknown `data-*`
attributes are not reported. Run it before you start and before finishing, as
`ts-build-jesse` describes. What needs judgment is in `checklist.md` of
`vue-review-jesse`.

## Project structure

Group by feature once the app has more than a handful of views; keep shared
building blocks small and generic.

```text
src/
├── main.ts               # createApp, plugins, mount
├── App.vue
├── router.ts             # Routes, guards, typed RouteMeta
├── api/
│   └── client.ts         # Transport and response parsing
├── stores/
│   └── session.ts        # useSessionStore
├── composables/
│   └── usePolling.ts     # Reusable stateful logic
├── components/
│   └── StatusPill.vue    # Presentational building blocks
└── features/
    └── composer/
        ├── ComposerView.vue
        ├── ComposerForm.vue
        └── useDraft.ts
```

- Component files are PascalCase (`unicorn/filename-case`); composables are
  `useX` in camelCase files.
- One component per file (`vue/one-component-per-file`); a component that grows
  past one responsibility splits into children with explicit props and events.

## Single-file components

- `<script setup lang="ts">` only (`vue/component-api-style`, `vue/block-lang`),
  ordered script, template, style (`vue/block-order`).
- Macros in order `defineOptions`, `defineModel`, `defineProps`, `defineEmits`,
  `defineSlots` (`vue/define-macros-order`), never imported
  (`vue/no-import-compiler-macros`).
- Type-based props and emits: `defineProps<{ … }>()` and
  `defineEmits<{ select: [id: ItemId] }>()` (`vue/define-props-declaration`,
  `vue/define-emits-declaration`). Default with reactive props destructure
  (`const { size = "md" } = defineProps<…>()`).
- Two-way binding uses `defineModel()`, not a prop plus `update:` emit pair.
- Typed template refs with `useTemplateRef()` (`vue/prefer-use-template-ref`);
  typed `ref<T>()` when the initial value does not determine the type
  (`vue/require-typed-ref`).
- Keep logic out of templates: a template expression reads state or calls one
  handler; compute anything else in script.
- Scoped or module styles; no static inline styles.

## Reactivity

- `ref()` for state; `reactive()` only for a fixed-shape object that is never
  replaced or destructured. `shallowRef()` or `markRaw()` for large or
  externally owned objects (editors, maps, chart instances).
- Derived state is `computed()`, never a ref kept in sync by a watcher.
  Computeds are pure and synchronous (`vue/no-side-effects-in-computed-properties`,
  `vue/no-async-in-computed-properties`).
- Destructuring props or refs keeps reactivity only through reactive props
  destructure or `toRefs()` (`vue/no-setup-props-reactivity-loss`,
  `vue/no-ref-object-reactivity-loss`).
- Watch a getter for anything that is not a ref or reactive object:
  `watch(() => props.id, …)` (`jesse/vue-watch-source-getter`). Use `watch` for
  side effects with explicit sources; set `immediate`, `once`, `deep` and
  `flush` deliberately. Cancel stale async work with `onWatcherCleanup()` and an
  `AbortController`.
- Never mutate props (`vue/no-mutating-props`); emit an event or use
  `defineModel()`.

## Composables

- Named `useX`, called unconditionally at the top of `<script setup>`, another
  composable or a setup store, never in callbacks, branches, loops or at module
  scope (`jesse/vue-composable-call-position`).
- Accept `MaybeRefOrGetter<T>` inputs and read them with `toValue()`; return an
  object of refs (or readonly refs), not a `reactive()` object.
- Release what you start: listeners, timers, observers and sockets stop in
  `onScopeDispose()` (or `onUnmounted()` when tied to a component). Prefer
  VueUse helpers already in the dependency graph over hand-written ones.
- Keep composables SSR-safe when the app renders on a server: no `window` or
  `document` access outside lifecycle hooks.

## State with Pinia

- Setup stores (`defineStore("session", () => { … })`) named `useXStore`, one
  per file, returning all their state (`pinia/*` rules).
- Consumers destructure state and getters with `storeToRefs()` and actions
  directly from the store (`jesse/vue-store-destructure`).
- Never export an initialized store or call one at module scope; call it in
  setup, a composable, an action or a navigation guard.
- Server data with caching needs belongs in the repository's query library
  (Pinia Colada or TanStack Query) rather than hand-rolled loading and error
  refs in every store.
- Keep state at the narrowest scope that works: local, then a composable, then
  `provide`/`inject` with a typed `InjectionKey` (`jesse/vue-no-string-injection-key`),
  then a store.

## Routing

- Route components load lazily: `component: () => import("./ComposerView.vue")`
  (`jesse/vue-lazy-route-component`).
- Guards return `false`, a route location or nothing; they do not take `next`
  (`jesse/vue-router-guard-no-next`).
- Navigate with named or typed locations, not concatenated paths. Type
  `RouteMeta` and route params through the router's typed-routes support.
- A component reused for a new param reloads its data: watch
  `() => route.params.id` or load in `onBeforeRouteUpdate`.
- Internal links are `<RouterLink>`, not `<a>` with a click handler.

## Templates

- Key `v-for` items by a stable identity, never their position
  (`jesse/vue-no-index-key`), and never by random or time-based values
  (`jesse/vue-no-random-key`); use `useId()` for generated element IDs.
- No `v-if` with `v-for` on one element (`vue/no-use-v-if-with-v-for`); filter
  in a computed.
- No `v-html` (`vue/no-v-html`) unless the source is trusted and sanitized;
  sanitize user-supplied URLs before binding them to `href` or `src`.
- Buttons declare their `type` (`vue/html-button-has-type`); `target="_blank"`
  links set `rel="noopener noreferrer"` (`vue/no-template-target-blank`).

## Accessibility

The vuejs-accessibility rules cover labels, alt text, keyboard handlers on
clickable elements and autofocus. Beyond them: use native interactive elements
before ARIA, manage focus when dialogs open and close and after navigation,
announce async status changes with a live region, and keep every action
reachable by keyboard.

## Performance

Measure before optimizing. Split routes and heavy components with async
components; keep props stable so children do not re-render; virtualize long
lists; use `v-memo`, `v-once` or `<KeepAlive :max>` only where a measurement
shows the need.

## Verify

Follow `ts-build-jesse`'s Verify section. Test components through their
rendered DOM, props and emitted events with `@vue/test-utils` or Testing
Library under the repository's runner, composables through a host component or
`withSetup` helper, and stores with a fresh Pinia per test. Use the
repository's end-to-end setup (Playwright when present) for flows that cross
routes or the network. Run the project's `vue-tsc` script as well as
`ts-lints`, since the project's own compiler options are what ships.
