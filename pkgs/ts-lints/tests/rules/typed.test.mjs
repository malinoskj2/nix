import path from "node:path";
import { fileURLToPath } from "node:url";
import plugin from "../../plugin/index.mjs";
import { TypedRuleTester } from "./setup.mjs";

const tester = new TypedRuleTester({
  languageOptions: {
    parserOptions: {
      projectService: true,
      tsconfigRootDir: path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "typed"),
    },
  },
});
const rules = plugin.rules;

tester.run("no-boolean-literal-argument", rules["no-boolean-literal-argument"], {
  valid: [
    "function render(layout: 'compact' | 'full') {} render('compact');",
    "function setVisible(visible: boolean) {} setVisible(true);",
    "const a = [1, 2].includes(1); console.assert(true);",
    "new Map([[1, true]]).set(2, false);",
  ],
  invalid: [
    { code: "function render(compact: boolean) {} render(true);", errors: [{ messageId: "literal" }] },
    {
      code: "class Panel { open(animate: boolean) {} } new Panel().open(false);",
      errors: [{ messageId: "literal" }],
    },
  ],
});

const store = `
declare function storeToRefs<T>(store: T): T;
interface Store { $id: string; count: number; doubled: number; increment(): void }
declare function useCounterStore(): Store;
`;

tester.run("vue-store-destructure", rules["vue-store-destructure"], {
  valid: [
    `${store} const { increment } = useCounterStore();`,
    `${store} const { count } = storeToRefs(useCounterStore());`,
  ],
  invalid: [
    { code: `${store} const { count, increment } = useCounterStore();`, errors: [{ messageId: "lost" }] },
  ],
});

const props = "declare const props: { id: string; nested: { a: number } };";

tester.run("vue-watch-source-getter (typed)", rules["vue-watch-source-getter"], {
  valid: [
    `import { watch } from 'vue'; ${props} watch(props.nested, () => {});`,
    `import { watch } from 'vue'; ${props} watch(() => props.id, () => {});`,
  ],
  invalid: [
    { code: `import { watch } from 'vue'; ${props} watch(props.id, () => {});`, errors: [{ messageId: "getter" }] },
  ],
});
