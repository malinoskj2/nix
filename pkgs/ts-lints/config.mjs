import fs from "node:fs";
import path from "node:path";
import comments from "@eslint-community/eslint-plugin-eslint-comments";
import { includeIgnoreFile } from "@eslint/compat";
import js from "@eslint/js";
import vitest from "@vitest/eslint-plugin";
import prettier from "eslint-config-prettier/flat";
import importX from "eslint-plugin-import-x";
import pinia from "eslint-plugin-pinia";
import regexp from "eslint-plugin-regexp";
import sonarjs from "eslint-plugin-sonarjs";
import unicorn from "eslint-plugin-unicorn";
import pluginVue from "eslint-plugin-vue";
import vueA11y from "eslint-plugin-vuejs-accessibility";
import { globalIgnores } from "eslint/config";
import tseslint from "typescript-eslint";
import vueParser from "vue-eslint-parser";
import jesse from "./plugin/index.mjs";

export const TS_FILES = ["**/*.ts", "**/*.tsx", "**/*.mts", "**/*.cts"];
export const VUE_FILES = ["**/*.vue"];
const ALL_FILES = [...TS_FILES, ...VUE_FILES];
const TEST_FILES = [
  "**/*.test.*",
  "**/*.spec.*",
  "**/__tests__/**",
  "**/tests/**",
  "**/test/**",
  "**/e2e/**",
];
const DEFAULT_EXPORT_FILES = [
  "**/*.config.*",
  "**/*.d.ts",
  "**/*.stories.*",
  "**/pages/**",
  "**/layouts/**",
  "**/middleware/**",
  "**/plugins/**",
  "**/server/**",
];

export const IGNORES = [
  "**/node_modules/",
  "**/dist/",
  "**/build/",
  "**/coverage/",
  "**/.tmp/",
  "**/.nuxt/",
  "**/.output/",
  "**/.vite/",
  "**/target/",
  "**/*.d.ts",
  "**/*.min.*",
];

const coreRules = {
  "arrow-body-style": "error",
  eqeqeq: ["error", "smart"],
  "logical-assignment-operators": "error",
  "max-depth": ["warn", 4],
  "max-nested-callbacks": ["warn", 4],
  "max-params": ["warn", 4],
  "no-alert": "error",
  "no-console": ["error", { allow: ["warn", "error"] }],
  "no-debugger": "error",
  "no-else-return": ["error", { allowElseIf: false }],
  "no-implicit-coercion": ["error", { boolean: false }],
  "no-lonely-if": "error",
  "no-promise-executor-return": "error",
  "no-unassigned-vars": "error",
  "no-undef-init": "error",
  "no-unneeded-ternary": "error",
  "no-useless-call": "error",
  "no-useless-computed-key": "error",
  "no-useless-concat": "error",
  "no-useless-rename": "error",
  "no-useless-return": "error",
  "no-var": "error",
  "object-shorthand": "error",
  "operator-assignment": "error",
  "prefer-arrow-callback": "error",
  "prefer-const": ["error", { destructuring: "all" }],
  "prefer-exponentiation-operator": "error",
  "prefer-numeric-literals": "error",
  "prefer-object-has-own": "error",
  "prefer-object-spread": "error",
  "prefer-regex-literals": "error",
  "prefer-rest-params": "error",
  "prefer-spread": "error",
  "prefer-template": "error",
  "preserve-caught-error": ["error", { requireCatchParameter: true }],
  radix: "error",
};

const typescriptRules = {
  "@typescript-eslint/array-type": ["error", { default: "array" }],
  "@typescript-eslint/consistent-type-assertions": [
    "error",
    { assertionStyle: "as", objectLiteralTypeAssertions: "allow-as-parameter" },
  ],
  "@typescript-eslint/consistent-type-definitions": ["error", "interface"],
  "@typescript-eslint/consistent-type-imports": ["error", { fixStyle: "inline-type-imports" }],
  "@typescript-eslint/explicit-module-boundary-types": "error",
  "@typescript-eslint/method-signature-style": ["error", "property"],
  "@typescript-eslint/no-confusing-void-expression": ["error", { ignoreVoidReturningFunctions: true }],
  "@typescript-eslint/no-import-type-side-effects": "error",
  "@typescript-eslint/no-inferrable-types": ["error", { ignoreParameters: true }],
  "@typescript-eslint/no-unused-vars": [
    "error",
    {
      args: "after-used",
      argsIgnorePattern: "^_",
      caughtErrorsIgnorePattern: "^_",
      destructuredArrayIgnorePattern: "^_",
      ignoreRestSiblings: true,
      varsIgnorePattern: "^_",
    },
  ],
  "@typescript-eslint/no-use-before-define": [
    "error",
    { classes: false, functions: false, ignoreTypeReferences: true, typedefs: false, variables: true },
  ],
};

const typedRules = {
  "@typescript-eslint/consistent-type-exports": "error",
  "@typescript-eslint/no-unsafe-type-assertion": "error",
  "@typescript-eslint/prefer-readonly": "error",
  "@typescript-eslint/promise-function-async": "error",
  "@typescript-eslint/require-array-sort-compare": ["error", { ignoreStringArrays: true }],
  "@typescript-eslint/restrict-template-expressions": ["error", { allowBoolean: true, allowNumber: true }],
  "@typescript-eslint/return-await": ["error", "in-try-catch"],
  "@typescript-eslint/strict-boolean-expressions": [
    "error",
    { allowNullableBoolean: true, allowNullableObject: true },
  ],
  "@typescript-eslint/strict-void-return": "error",
  "@typescript-eslint/switch-exhaustiveness-check": [
    "error",
    { considerDefaultExhaustiveForUnions: false, requireDefaultForNonUnion: true },
  ],
};

const pluginRules = {
  "@eslint-community/eslint-comments/disable-enable-pair": ["error", { allowWholeFile: true }],
  "@eslint-community/eslint-comments/no-aggregating-enable": "error",
  "@eslint-community/eslint-comments/no-duplicate-disable": "error",
  "@eslint-community/eslint-comments/no-unlimited-disable": "error",
  "@eslint-community/eslint-comments/no-unused-enable": "error",
  "@eslint-community/eslint-comments/require-description": "error",
  "import-x/first": "error",
  "import-x/no-absolute-path": "error",
  "import-x/no-amd": "error",
  "import-x/no-default-export": "error",
  "import-x/no-duplicates": "error",
  "import-x/no-empty-named-blocks": "error",
  "import-x/no-mutable-exports": "error",
  "import-x/no-named-default": "error",
  "import-x/no-self-import": "error",
  "sonarjs/cognitive-complexity": ["warn", 15],
  "sonarjs/no-all-duplicated-branches": "error",
  "sonarjs/no-collapsible-if": "error",
  "sonarjs/no-commented-code": "error",
  "sonarjs/no-dead-store": "error",
  "sonarjs/no-duplicated-branches": "error",
  "sonarjs/no-element-overwrite": "error",
  "sonarjs/no-empty-collection": "error",
  "sonarjs/no-gratuitous-expressions": "error",
  "sonarjs/no-identical-conditions": "error",
  "sonarjs/no-identical-expressions": "error",
  "sonarjs/no-identical-functions": "error",
  "sonarjs/no-invariant-returns": "error",
  "sonarjs/no-inverted-boolean-check": "error",
  "sonarjs/no-redundant-boolean": "error",
  "sonarjs/no-redundant-jump": "error",
  "sonarjs/no-unused-collection": "error",
  "sonarjs/no-use-of-empty-return-value": "error",
  "sonarjs/prefer-single-boolean-return": "error",
  "unicorn/consistent-empty-array-spread": "error",
  "unicorn/error-message": "error",
  "unicorn/new-for-builtins": "error",
  "unicorn/no-accessor-recursion": "error",
  "unicorn/no-instanceof-builtins": "error",
  "unicorn/no-length-as-slice-end": "error",
  "unicorn/no-new-array": "error",
  "unicorn/no-single-promise-in-promise-methods": "error",
  "unicorn/no-typeof-undefined": "error",
  "unicorn/no-useless-promise-resolve-reject": "error",
  "unicorn/no-useless-spread": "error",
  "unicorn/prefer-array-flat-map": "error",
  "unicorn/prefer-array-some": "error",
  "unicorn/prefer-at": "error",
  "unicorn/prefer-export-from": "error",
  "unicorn/prefer-includes": "error",
  "unicorn/prefer-node-protocol": "error",
  "unicorn/prefer-number-properties": "error",
  "unicorn/prefer-regexp-test": "error",
  "unicorn/prefer-string-replace-all": "error",
  "unicorn/prefer-structured-clone": "error",
  "unicorn/prefer-type-error": "error",
  "unicorn/throw-new-error": "error",
};

const jesseRules = {
  "jesse/no-barrel-file": "error",
  "jesse/no-boolean-literal-argument": "error",
  "jesse/no-catch-all-module": "error",
  "jesse/no-double-assertion": "error",
  "jesse/no-error-message-matching": "error",
  "jesse/no-file-header-comment": "error",
  "jesse/no-swallowed-catch": "error",
  "jesse/no-sync-call-in-async": "error",
  "jesse/no-unbounded-promise-all": "warn",
  "jesse/no-unvalidated-parse": "error",
};

const jesseVueRules = {
  "jesse/vue-composable-call-position": "error",
  "jesse/vue-lazy-route-component": "error",
  "jesse/vue-no-index-key": "error",
  "jesse/vue-no-random-key": "error",
  "jesse/vue-no-string-injection-key": "error",
  "jesse/vue-router-guard-no-next": "error",
  "jesse/vue-store-destructure": "error",
  "jesse/vue-watch-source-getter": "error",
};

const vueRules = {
  "vue/block-lang": ["error", { script: { lang: "ts" } }],
  "vue/block-order": ["error", { order: ["script", "template", "style"] }],
  "vue/component-api-style": ["error", ["script-setup"]],
  "vue/custom-event-name-casing": ["error", "camelCase"],
  "vue/define-emits-declaration": ["error", "type-literal"],
  "vue/define-macros-order": [
    "error",
    { order: ["defineOptions", "defineModel", "defineProps", "defineEmits", "defineSlots"] },
  ],
  "vue/define-props-declaration": ["error", "type-based"],
  "vue/dot-notation": "error",
  "vue/eqeqeq": ["error", "smart"],
  "vue/html-button-has-type": "error",
  "vue/multi-word-component-names": "off",
  "vue/next-tick-style": ["error", "promise"],
  "vue/no-duplicate-attr-inheritance": "error",
  "vue/no-empty-component-block": "error",
  "vue/no-import-compiler-macros": "error",
  "vue/no-multiple-objects-in-class": "error",
  "vue/no-ref-object-reactivity-loss": "error",
  "vue/no-restricted-v-bind": ["error", "/^v-/"],
  "vue/no-root-v-if": "error",
  "vue/no-setup-props-reactivity-loss": "error",
  "vue/no-template-target-blank": "error",
  "vue/no-undef-properties": "error",
  "vue/no-unused-emit-declarations": "error",
  "vue/no-unused-properties": ["error", { groups: ["props", "setup"] }],
  "vue/no-unused-refs": "error",
  "vue/no-useless-mustaches": "error",
  "vue/no-useless-v-bind": "error",
  "vue/object-shorthand": "error",
  "vue/prefer-define-options": "error",
  "vue/prefer-separate-static-class": "error",
  "vue/prefer-template": "error",
  "vue/prefer-true-attribute-shorthand": "error",
  "vue/prefer-use-template-ref": "error",
  "vue/require-default-prop": "off",
  "vue/require-macro-variable-name": "error",
  "vue/require-prop-types": "off",
  "vue/require-typed-ref": "error",
};

const testOverrides = {
  "@typescript-eslint/no-non-null-assertion": "off",
  "@typescript-eslint/unbound-method": "off",
  "jesse/no-boolean-literal-argument": "off",
  "jesse/vue-composable-call-position": "off",
  "max-nested-callbacks": "off",
  "no-console": "off",
  "sonarjs/no-identical-functions": "off",
};

const vitestRules = {
  ...vitest.configs.recommended.rules,
  "vitest/no-disabled-tests": "error",
  "vitest/no-focused-tests": "error",
};

function scoped(configs, files) {
  return configs.map((config) => ({ ...config, files }));
}

export function createConfig({ root, vue, vitest: usesVitest, typed }) {
  const gitignore = path.join(root, ".gitignore");
  const config = [
    globalIgnores(IGNORES),
    ...(fs.existsSync(gitignore) ? [includeIgnoreFile(gitignore)] : []),
    {
      files: ALL_FILES,
      linterOptions: { reportUnusedDisableDirectives: "error", reportUnusedInlineConfigs: "error" },
    },
    { ...js.configs.recommended, files: ALL_FILES },
    ...scoped(typed ? tseslint.configs.strictTypeChecked : tseslint.configs.strict, ALL_FILES),
    ...scoped(typed ? tseslint.configs.stylisticTypeChecked : tseslint.configs.stylistic, ALL_FILES),
  ];

  if (vue) {
    config.push(
      ...pluginVue.configs["flat/recommended-error"].map((entry) => ({ ...entry, files: entry.files ?? VUE_FILES })),
      ...scoped(vueA11y.configs["flat/recommended"], VUE_FILES),
      {
        files: VUE_FILES,
        languageOptions: {
          parser: vueParser,
          parserOptions: { parser: tseslint.parser, sourceType: "module" },
        },
      },
      { ...pinia.configs["recommended-flat"], files: ALL_FILES },
    );
  }

  config.push(
    {
      files: ALL_FILES,
      languageOptions: {
        parserOptions: {
          extraFileExtensions: vue ? [".vue"] : [],
          ...(typed ? { projectService: true, tsconfigRootDir: root } : {}),
        },
      },
    },
    { ...regexp.configs["flat/recommended"], files: ALL_FILES },
    { ...prettier, files: ALL_FILES },
    {
      files: ALL_FILES,
      plugins: {
        "@eslint-community/eslint-comments": comments,
        "import-x": importX,
        jesse,
        sonarjs,
        unicorn,
      },
      rules: {
        ...coreRules,
        ...typescriptRules,
        ...(typed ? typedRules : {}),
        ...pluginRules,
        ...jesseRules,
        ...(vue ? jesseVueRules : {}),
      },
    },
    {
      files: TS_FILES,
      plugins: { unicorn },
      rules: { "unicorn/filename-case": ["error", { cases: { camelCase: true, kebabCase: true } }] },
    },
  );

  if (vue) {
    config.push({
      files: VUE_FILES,
      plugins: { unicorn },
      rules: {
        ...vueRules,
        "unicorn/filename-case": ["error", { cases: { kebabCase: true, pascalCase: true } }],
      },
    });
  }

  config.push(
    { files: DEFAULT_EXPORT_FILES, rules: { "import-x/no-default-export": "off" } },
    { files: TEST_FILES, rules: testOverrides },
  );

  if (usesVitest) {
    config.push({ files: TEST_FILES, plugins: { vitest }, rules: vitestRules });
  }

  if (!typed) {
    config.push({ ...tseslint.configs.disableTypeChecked, files: ALL_FILES });
  }
  return config;
}
