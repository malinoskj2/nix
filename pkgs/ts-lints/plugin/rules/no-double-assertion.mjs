import { createRule } from "../ast.mjs";

const ASSERTIONS = new Set(["TSAsExpression", "TSTypeAssertion"]);
const ESCAPES = new Set(["TSUnknownKeyword", "TSAnyKeyword"]);

export default createRule({
  name: "no-double-assertion",
  meta: {
    type: "problem",
    docs: { description: "Disallow asserting through unknown or any to force an unrelated type" },
    messages: {
      double: "Double assertion through `{{via}}`: parse or narrow the value instead of forcing its type.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    function check(node) {
      const inner = node.expression;
      if (ASSERTIONS.has(inner.type) && ESCAPES.has(inner.typeAnnotation.type)) {
        const via = inner.typeAnnotation.type === "TSAnyKeyword" ? "any" : "unknown";
        context.report({ node, messageId: "double", data: { via } });
      }
    }
    return { TSAsExpression: check, TSTypeAssertion: check };
  },
});
