import { createRule, importedFrom } from "../ast.mjs";

export default createRule({
  name: "vue-no-string-injection-key",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow string keys for provide and inject" },
    messages: {
      stringKey: "`{{name}}` with a string key is untyped and can collide: export a typed `InjectionKey` symbol.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    let imports = null;
    return {
      CallExpression(node) {
        imports ??= importedFrom(context, ["vue"]);
        if (node.callee.type !== "Identifier") {
          return;
        }
        const name = imports.get(node.callee.name);
        if (name !== "provide" && name !== "inject") {
          return;
        }
        const [key] = node.arguments;
        if ((key?.type === "Literal" && typeof key.value === "string") || key?.type === "TemplateLiteral") {
          context.report({ node: key, messageId: "stringKey", data: { name } });
        }
      },
    };
  },
});
