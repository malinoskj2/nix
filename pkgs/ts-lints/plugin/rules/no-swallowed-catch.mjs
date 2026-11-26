import { createRule } from "../ast.mjs";

function isEmptyValue(node) {
  if (node === null) {
    return true;
  }
  switch (node.type) {
    case "Literal":
      return node.value === null || node.value === false;
    case "Identifier":
      return node.name === "undefined";
    case "ArrayExpression":
      return node.elements.length === 0;
    case "ObjectExpression":
      return node.properties.length === 0;
    default:
      return false;
  }
}

export default createRule({
  name: "no-swallowed-catch",
  meta: {
    type: "problem",
    docs: { description: "Disallow a catch that discards the error and returns an empty value" },
    messages: {
      swallowed: "This catch discards the error and returns an empty value: handle it, add context and rethrow, or return a typed failure.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      CatchClause(node) {
        const body = node.body.body;
        if (body.length !== 1 || body[0].type !== "ReturnStatement" || !isEmptyValue(body[0].argument)) {
          return;
        }
        if (node.param) {
          const used = context.sourceCode.getDeclaredVariables(node).some((variable) => variable.references.length > 0);
          if (used) {
            return;
          }
        }
        context.report({ node, messageId: "swallowed" });
      },
    };
  },
});
