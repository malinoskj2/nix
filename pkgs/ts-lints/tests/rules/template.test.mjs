import tseslint from "typescript-eslint";
import vueParser from "vue-eslint-parser";
import plugin from "../../plugin/index.mjs";
import { RuleTester } from "./setup.mjs";

const tester = new RuleTester({
  languageOptions: { parser: vueParser, parserOptions: { parser: tseslint.parser, sourceType: "module" } },
});
const rules = plugin.rules;

function sfc(template) {
  return { code: `<template>${template}</template>`, filename: "List.vue" };
}

tester.run("vue-no-index-key", rules["vue-no-index-key"], {
  valid: [
    sfc('<li v-for="item in items" :key="item.id">{{ item.name }}</li>'),
    sfc('<li v-for="(item, i) in items" :key="`${item.id}-${i}`">{{ i }}</li>'),
    sfc('<li v-for="(value, key) in record" :key="key">{{ value }}</li>'),
    sfc('<li v-for="n in 5" :key="n">{{ n }}</li>'),
  ],
  invalid: [
    { ...sfc('<li v-for="(item, i) in items" :key="i">{{ item }}</li>'), errors: [{ messageId: "indexKey" }] },
    { ...sfc('<li v-for="(item, index) in items" :key="`row-${index}`">{{ item }}</li>'), errors: [{ messageId: "indexKey" }] },
    {
      ...sfc('<template v-for="(item, i) in items"><li :key="i">{{ item }}</li></template>'),
      errors: [{ messageId: "indexKey" }],
    },
    { ...sfc('<li v-for="(value, key, i) in record" :key="i">{{ value }}</li>'), errors: [{ messageId: "indexKey" }] },
  ],
});

tester.run("vue-no-random-key", rules["vue-no-random-key"], {
  valid: [sfc('<input :id="id" />'), sfc('<li v-for="item in items" :key="item.id" />')],
  invalid: [
    { ...sfc('<li v-for="item in items" :key="Math.random()" />'), errors: [{ messageId: "random" }] },
    { ...sfc('<input :id="`field-${Date.now()}`" />'), errors: [{ messageId: "random" }] },
  ],
});
