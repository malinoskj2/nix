import { createRule } from "../ast.mjs";

const COMBINATORS = new Set(["all", "allSettled", "any", "race"]);

export default createRule({
  name: "no-unbounded-promise-all",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow starting one promise per element of a collection of unknown size" },
    messages: {
      unbounded: "`Promise.{{name}}` over `.map()` starts every operation at once: bound the concurrency or prove the collection is small.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      CallExpression(node) {
        const callee = node.callee;
        if (
          callee.type !== "MemberExpression" ||
          callee.computed ||
          callee.object.type !== "Identifier" ||
          callee.object.name !== "Promise" ||
          !COMBINATORS.has(callee.property.name)
        ) {
          return;
        }
        const [arg] = node.arguments;
        if (
          arg?.type === "CallExpression" &&
          arg.callee.type === "MemberExpression" &&
          !arg.callee.computed &&
          arg.callee.property.name === "map" &&
          arg.callee.object.type !== "ArrayExpression"
        ) {
          context.report({ node, messageId: "unbounded", data: { name: callee.property.name } });
        }
      },
    };
  },
});
