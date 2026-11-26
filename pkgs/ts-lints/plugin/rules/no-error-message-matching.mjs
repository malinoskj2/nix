import { createRule } from "../ast.mjs";

const MATCHERS = new Set(["includes", "startsWith", "endsWith", "match", "indexOf", "search"]);

function isMessage(node) {
  return (
    node?.type === "MemberExpression" &&
    !node.computed &&
    node.property.type === "Identifier" &&
    node.property.name === "message"
  );
}

function isText(node) {
  return (node.type === "Literal" && typeof node.value === "string") || node.type === "TemplateLiteral";
}

export default createRule({
  name: "no-error-message-matching",
  meta: {
    type: "problem",
    docs: { description: "Disallow branching on the text of an error message" },
    messages: {
      matching: "Matching on an error message: branch on the error's type, code or a typed result instead.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      CallExpression(node) {
        const callee = node.callee;
        if (callee.type !== "MemberExpression" || callee.computed || callee.property.type !== "Identifier") {
          return;
        }
        const name = callee.property.name;
        if (MATCHERS.has(name) && isMessage(callee.object)) {
          context.report({ node, messageId: "matching" });
        } else if (name === "test" && callee.object.type === "Literal" && isMessage(node.arguments[0])) {
          context.report({ node, messageId: "matching" });
        }
      },
      BinaryExpression(node) {
        if (!["===", "!==", "==", "!="].includes(node.operator)) {
          return;
        }
        if ((isMessage(node.left) && isText(node.right)) || (isMessage(node.right) && isText(node.left))) {
          context.report({ node, messageId: "matching" });
        }
      },
    };
  },
});
