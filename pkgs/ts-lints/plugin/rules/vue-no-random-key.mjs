import { createRule, templateVisitor } from "../ast.mjs";

const TARGETS = new Set(["key", "id", "for"]);

function randomCall(node) {
  let found = null;
  (function walk(current) {
    if (found || !current || typeof current.type !== "string") {
      return;
    }
    if (current.type === "CallExpression" && current.callee.type === "MemberExpression" && !current.callee.computed) {
      const object = current.callee.object;
      const name = `${object.type === "Identifier" ? object.name : ""}.${current.callee.property.name}`;
      if (["Math.random", "Date.now", "crypto.randomUUID"].includes(name)) {
        found = name;
        return;
      }
    }
    for (const [key, value] of Object.entries(current)) {
      if (key === "parent") {
        continue;
      }
      if (Array.isArray(value)) {
        value.forEach(walk);
      } else if (value && typeof value.type === "string") {
        walk(value);
      }
    }
  })(node);
  return found;
}

export default createRule({
  name: "vue-no-random-key",
  meta: {
    type: "problem",
    docs: { description: "Disallow random or time-based values for key, id and for bindings" },
    messages: {
      random: "`:{{attribute}}` built from `{{call}}()` changes on every render and between server and client: use a stable key or `useId()`.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return templateVisitor(context, {
      "VAttribute[directive=true][key.name.name='bind']"(attribute) {
        const argument = attribute.key.argument;
        if (argument?.type !== "VIdentifier" || !TARGETS.has(argument.name)) {
          return;
        }
        const call = randomCall(attribute.value?.expression);
        if (call) {
          context.report({ node: attribute, messageId: "random", data: { attribute: argument.name, call } });
        }
      },
    });
  },
});
