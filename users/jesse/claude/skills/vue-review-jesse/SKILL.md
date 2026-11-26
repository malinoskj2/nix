---
name: vue-review-jesse
description: Review Vue 3 changes for requirement coverage, reactivity correctness, component and state design, routing, accessibility and template safety. Use for review-only requests together with ts-review-jesse and report findings without editing.
---

# Vue review

Use the target from `$ARGUMENTS` when present; otherwise use the request or
delegation. Explicit requirements and repository instructions define the review
bar. This workflow is read-only.

Follow `ts-review-jesse` for scope, the `ts-lints` pass, the TypeScript review
priorities, its checklist and the report format. This skill adds what is
specific to Vue.

## Mechanized rules

In a Vue project `ts-lints` adds eslint-plugin-vue (`flat/recommended-error`
plus the uncategorized rules in `config.mjs`), vuejs-accessibility, pinia, the
`jesse/vue-*` rules and a `vue-tsc` type check with `strictTemplates`. Report
its findings in scope with their rule names. A notice that the project was
linted without types means template type errors and the typed `jesse/vue-*`
checks were not run; say so. Review what the lints cannot see with
[`checklist.md`](checklist.md).

## Review priorities

Apply these within `ts-review-jesse`'s priorities.

1. **Requirement coverage:** the feature works through its real route,
   component and store, including loading, empty, error and permission states.
2. **Reactivity correctness:** no lost reactivity
   (`vue/no-setup-props-reactivity-loss`, `vue/no-ref-object-reactivity-loss`,
   `jesse/vue-store-destructure`, `jesse/vue-watch-source-getter`); derived
   state is computed rather than synchronized; watchers cancel stale async
   work; composables run in setup (`jesse/vue-composable-call-position`) and
   release what they start.
3. **Component and state design:** minimal typed props, events named for
   intent, slots over configuration props, state at the narrowest scope, typed
   injection keys (`jesse/vue-no-string-injection-key`), setup stores consumed
   through `storeToRefs()`.
4. **Routing:** lazy route components (`jesse/vue-lazy-route-component`),
   guards that return locations (`jesse/vue-router-guard-no-next`), param
   changes reload data, typed locations and meta.
5. **Template safety and accessibility:** stable keys (`jesse/vue-no-index-key`,
   `jesse/vue-no-random-key`), no unsanitized `v-html` or URLs, vuejs-accessibility
   findings, focus management and keyboard paths.
6. **Performance:** only measured optimizations; no needless watchers, deep
   watches or unstable props in hot lists.
7. **Tests:** components tested through the DOM and emitted events, composables
   and stores in isolation, flows end to end where they cross routes.

## Report

Use `ts-review-jesse`'s report format, one findings list covering TypeScript
and Vue.
