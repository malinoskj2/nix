import { calleeName, createRule } from "../ast.mjs";

const GUARDS = new Set(["beforeEach", "beforeResolve", "onBeforeRouteLeave", "onBeforeRouteUpdate"]);
const FUNCTIONS = new Set(["FunctionExpression", "ArrowFunctionExpression"]);

export default createRule({
  name: "vue-router-guard-no-next",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow the next callback in navigation guards" },
    messages: {
      next: "Navigation guard takes `next`: return `false`, a route location or nothing instead.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    function check(fn) {
      if (fn && FUNCTIONS.has(fn.type) && fn.params.length >= 3) {
        context.report({ node: fn.params[2], messageId: "next" });
      }
    }
    return {
      CallExpression(node) {
        const name = calleeName(node);
        if (name && GUARDS.has(name)) {
          check(node.arguments[0]);
        }
      },
      "Property[key.name='beforeEnter']"(node) {
        check(node.value);
      },
    };
  },
});
