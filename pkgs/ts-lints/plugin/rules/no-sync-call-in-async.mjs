import { calleeName, createRule, enclosingFunction } from "../ast.mjs";

export default createRule({
  name: "no-sync-call-in-async",
  meta: {
    type: "problem",
    docs: { description: "Disallow blocking synchronous calls inside async functions" },
    messages: {
      blocking: "`{{name}}` blocks the event loop inside an async function: use its promise-based form.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      CallExpression(node) {
        const name = calleeName(node);
        if (!name || !/^[a-z]\w*Sync$/.test(name)) {
          return;
        }
        if (enclosingFunction(node)?.async) {
          context.report({ node, messageId: "blocking", data: { name } });
        }
      },
    };
  },
});
