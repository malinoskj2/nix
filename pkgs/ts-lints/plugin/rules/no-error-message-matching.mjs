import ts from "typescript";
import { createRule, typeServices } from "../ast.mjs";

const ERROR_NAME = /^(?:e|err|error|ex|exception|reason|cause|\w+Error|\w+Err)$/;

function catchParameterNames(node, names = new Set()) {
  for (let current = node.parent; current; current = current.parent) {
    if (current.type === "CatchClause" && current.param?.type === "Identifier") {
      names.add(current.param.name);
    }
  }
  return names;
}

function isErrorType(type) {
  if (type.isUnion()) {
    return type.types.every(isErrorType);
  }
  return Boolean(type.getProperty("message") && type.getProperty("name") && type.getProperty("stack"));
}

const MATCHERS = new Set(["includes", "startsWith", "endsWith", "match", "indexOf", "search"]);


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
    const services = typeServices(context);
    function isErrorValue(node) {
      if (services) {
        const type = services.getTypeAtLocation(node);
        const unresolved = (type.flags & (ts.TypeFlags.Any | ts.TypeFlags.Unknown)) !== 0;
        if (!unresolved) {
          return isErrorType(type);
        }
      }
      return node.type === "Identifier" && (ERROR_NAME.test(node.name) || catchParameterNames(node).has(node.name));
    }
    function isMessage(node) {
      return (
        node?.type === "MemberExpression" &&
        !node.computed &&
        node.property.type === "Identifier" &&
        node.property.name === "message" &&
        isErrorValue(node.object)
      );
    }
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
