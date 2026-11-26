import { createRule } from "../ast.mjs";

function unwrap(node) {
  let current = node;
  while (current.type === "AwaitExpression" || current.type === "ChainExpression") {
    current = current.type === "AwaitExpression" ? current.argument : current.expression;
  }
  return current;
}

function parseSource(node) {
  if (node.type !== "CallExpression" || node.callee.type !== "MemberExpression" || node.callee.computed) {
    return null;
  }
  const { object, property } = node.callee;
  if (object.type === "Identifier" && object.name === "JSON" && property.name === "parse") {
    return "JSON.parse()";
  }
  if (property.name === "json" && node.arguments.length === 0) {
    return ".json()";
  }
  return null;
}

export default createRule({
  name: "no-unvalidated-parse",
  meta: {
    type: "problem",
    docs: { description: "Disallow asserting a type onto parsed JSON instead of validating it" },
    messages: {
      unvalidated: "`{{source}}` asserted to a type: validate it with a schema at this boundary instead.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    function check(node) {
      if (node.typeAnnotation.type === "TSUnknownKeyword") {
        return;
      }
      const source = parseSource(unwrap(node.expression));
      if (source) {
        context.report({ node, messageId: "unvalidated", data: { source } });
      }
    }
    return { TSAsExpression: check, TSTypeAssertion: check };
  },
});
