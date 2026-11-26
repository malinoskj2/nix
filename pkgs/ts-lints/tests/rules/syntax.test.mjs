import tseslint from "typescript-eslint";
import plugin from "../../plugin/index.mjs";
import { RuleTester } from "./setup.mjs";

const tester = new RuleTester({ languageOptions: { parser: tseslint.parser } });
const rules = plugin.rules;

tester.run("no-catch-all-module", rules["no-catch-all-module"], {
  valid: [
    { code: "export const a = 1;", filename: "src/session.ts" },
    { code: "export const a = 1;", filename: "src/format/index.ts" },
  ],
  invalid: [
    { code: "export const a = 1;", filename: "src/utils.ts", errors: [{ messageId: "catchAll" }] },
    { code: "export const a = 1;", filename: "src/helpers/date.ts", errors: [{ messageId: "catchAll" }] },
    { code: "export const a = 1;", filename: "src/common/index.ts", errors: [{ messageId: "catchAll" }] },
    { code: "export const a = 1;", filename: "src/constants.test.ts", errors: [{ messageId: "catchAll" }] },
  ],
});

tester.run("no-barrel-file", rules["no-barrel-file"], {
  valid: [
    { code: "export * from './a';", filename: "/nonexistent/src/feature/a.ts" },
    { code: "export * from './a';\nexport const b = 1;", filename: "/nonexistent/src/feature/index.ts" },
  ],
  invalid: [
    {
      code: "export * from './a';\nexport { b } from './b';",
      filename: "/nonexistent/src/feature/index.ts",
      errors: [{ messageId: "barrel" }],
    },
  ],
});

tester.run("no-file-header-comment", rules["no-file-header-comment"], {
  valid: [
    "export const a = 1;",
    "// eslint-disable-next-line no-console -- startup banner\nconsole.log(1);",
    "/*! license */\nexport const a = 1;",
    "/// <reference types=\"vite/client\" />\nexport const a = 1;",
    "import a from 'a';\n// why this ordering matters\nexport const b = a;",
    "/** @deprecated Use `load` instead. */\nexport function fetchAll() {}",
    "// Retries stop after the deadline because the upstream bills per call.\nexport const retries = 3;",
  ],
  invalid: [
    { code: "// Session storage helpers.\n\nexport const a = 1;", errors: [{ messageId: "header" }] },
    { code: "/**\n * The router module.\n */\nimport a from 'a';\nexport const b = a;", errors: [{ messageId: "header" }] },
  ],
});

tester.run("no-error-message-matching", rules["no-error-message-matching"], {
  valid: [
    "if (error instanceof TimeoutError) retry();",
    "log(error.message);",
    "if (error.code === 'ENOENT') {}",
    "if (chat.message.includes('hello')) highlight();",
  ],
  invalid: [
    { code: "if (error.message.includes('timeout')) retry();", errors: [{ messageId: "matching" }] },
    { code: "if (e.message === 'not found') {}", errors: [{ messageId: "matching" }] },
    { code: "if (/denied/.test(err.message)) {}", errors: [{ messageId: "matching" }] },
    { code: "try { a(); } catch (failure) { if (failure.message.startsWith('x')) {} }", errors: [{ messageId: "matching" }] },
  ],
});

tester.run("no-double-assertion", rules["no-double-assertion"], {
  valid: ["const a = b as A;", "const a = b as unknown;"],
  invalid: [
    { code: "const a = b as unknown as A;", errors: [{ messageId: "double", data: { via: "unknown" } }] },
    { code: "const a = b as any as A;", errors: [{ messageId: "double", data: { via: "any" } }] },
  ],
});

tester.run("no-unvalidated-parse", rules["no-unvalidated-parse"], {
  valid: ["const a = schema.parse(JSON.parse(text));", "const a = JSON.parse(text) as unknown;", "const a = value as A;"],
  invalid: [
    { code: "const a = JSON.parse(text) as Config;", errors: [{ messageId: "unvalidated" }] },
    { code: "const a = (await response.json()) as User[];", errors: [{ messageId: "unvalidated" }] },
  ],
});

tester.run("no-swallowed-catch", rules["no-swallowed-catch"], {
  valid: [
    "try { a(); } catch (error) { log(error); return null; }",
    "try { a(); } catch (error) { return fallback(error); }",
    "try { a(); } catch { return defaultValue; }",
  ],
  invalid: [
    { code: "function f() { try { a(); } catch { return null; } }", errors: [{ messageId: "swallowed" }] },
    { code: "function f() { try { a(); } catch (e) { return []; } }", errors: [{ messageId: "swallowed" }] },
    { code: "function f() { try { a(); } catch (_e) { return; } }", errors: [{ messageId: "swallowed" }] },
  ],
});

tester.run("no-sync-call-in-async", rules["no-sync-call-in-async"], {
  valid: ["function f() { fs.readFileSync(p); }", "async function f() { await fs.promises.readFile(p); }"],
  invalid: [
    { code: "async function f() { fs.readFileSync(p); }", errors: [{ messageId: "blocking" }] },
    { code: "const f = async () => execSync('ls');", errors: [{ messageId: "blocking" }] },
  ],
});

tester.run("no-unbounded-promise-all", rules["no-unbounded-promise-all"], {
  valid: ["await Promise.all([a(), b()]);", "await Promise.all([a, b].map(load));", "await mapLimit(ids, 4, load);"],
  invalid: [{ code: "await Promise.all(ids.map(load));", errors: [{ messageId: "unbounded" }] }],
});

tester.run("vue-composable-call-position", rules["vue-composable-call-position"], {
  valid: [
    { code: "export function useA() { const b = useB(); return b; }", filename: "a.ts" },
    { code: "export const useStore = defineStore('a', () => { const r = useRoute(); return { r }; });", filename: "a.ts" },
    { code: "router.beforeEach(() => { const s = useSessionStore(); });", filename: "router.ts" },
    { code: "const route = useRoute();", filename: "View.vue", languageOptions: { parser: tseslint.parser } },
  ],
  invalid: [
    { code: "const route = useRoute();", filename: "a.ts", errors: [{ messageId: "moduleScope" }] },
    { code: "const session = useSessionStore();", filename: "a.ts", errors: [{ messageId: "moduleScope" }] },
    { code: "export function useA() { onMounted(() => { useB(); }); }", filename: "a.ts", errors: [{ messageId: "nested" }] },
    { code: "export function useA(x) { if (x) { useB(); } }", filename: "a.ts", errors: [{ messageId: "conditional" }] },
    { code: "export function useA(xs) { for (const x of xs) useB(x); }", filename: "a.ts", errors: [{ messageId: "conditional" }] },
  ],
});

tester.run("vue-no-string-injection-key", rules["vue-no-string-injection-key"], {
  valid: [
    "import { provide } from 'vue'; provide(ThemeKey, theme);",
    "import { inject } from 'other'; inject('theme');",
    "app.provide('theme', theme);",
  ],
  invalid: [
    { code: "import { provide } from 'vue'; provide('theme', theme);", errors: [{ messageId: "stringKey" }] },
    { code: "import { inject as use } from 'vue'; use(`theme`);", errors: [{ messageId: "stringKey" }] },
  ],
});

tester.run("vue-watch-source-getter", rules["vue-watch-source-getter"], {
  valid: [
    "import { watch } from 'vue'; watch(() => props.id, load);",
    "import { watch } from 'vue'; watch(count, log);",
    "import { watch } from 'vue'; watch(state.count.value, log);",
  ],
  invalid: [
    { code: "import { watch } from 'vue'; watch(props.id, load);", errors: [{ messageId: "getter" }] },
    { code: "import { watch } from 'vue'; watch([a, props.b], load);", errors: [{ messageId: "getter" }] },
  ],
});

tester.run("vue-lazy-route-component", rules["vue-lazy-route-component"], {
  valid: [
    "const routes = [{ path: '/', component: () => import('./Home.vue') }];",
    "import Tab from './Tab.vue'; const tabs = [{ name: 'a', component: Tab }];",
  ],
  invalid: [
    {
      code: "import Home from './Home.vue'; const routes = [{ path: '/', component: Home }];",
      errors: [{ messageId: "eager" }],
    },
  ],
});

tester.run("vue-router-guard-no-next", rules["vue-router-guard-no-next"], {
  valid: ["router.beforeEach((to) => to.meta.public || { name: 'login' });", "const r = { beforeEnter: (to) => true };"],
  invalid: [
    { code: "router.beforeEach((to, from, next) => next());", errors: [{ messageId: "next" }] },
    { code: "const r = { path: '/', beforeEnter(to, from, next) { next(); } };", errors: [{ messageId: "next" }] },
  ],
});
