import { createRule, enclosingFunction, functionName, typeServices } from "../ast.mjs";

const COMPOSABLE = /^use[A-Z0-9]/;

function isSetupFunction(fn) {
  const name = functionName(fn);
  if (name && (COMPOSABLE.test(name) || name === "setup")) {
    return true;
  }
  const parent = fn.parent;
  return (
    parent.type === "CallExpression" &&
    parent.callee.type === "Identifier" &&
    parent.callee.name === "defineStore" &&
    parent.arguments.includes(fn)
  );
}

function conditionalAncestor(node, boundary) {
  let child = node;
  for (let current = node.parent; current && current !== boundary; current = current.parent) {
    switch (current.type) {
      case "IfStatement":
      case "ConditionalExpression":
        if (current.test !== child) {
          return current;
        }
        break;
      case "LogicalExpression":
        if (current.right === child) {
          return current;
        }
        break;
      case "SwitchCase":
      case "ForStatement":
      case "ForInStatement":
      case "ForOfStatement":
      case "WhileStatement":
      case "DoWhileStatement":
        return current;
      default:
        break;
    }
    child = current;
  }
  return null;
}

export default createRule({
  name: "vue-composable-call-position",
  meta: {
    type: "problem",
    docs: { description: "Require composables to be called unconditionally at the top of setup or another composable; Pinia store accessors may also be called in callbacks such as navigation guards" },
    messages: {
      moduleScope: "`{{name}}()` at module scope runs outside any component or effect scope: call it inside setup or a composable.",
      nested: "`{{name}}()` inside a callback runs outside setup: call it at the top of setup or a composable and use its result here.",
      conditional: "`{{name}}()` is called conditionally or in a loop: call it unconditionally and branch on its result.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    const isVue = context.filename.endsWith(".vue");
    const services = typeServices(context);
    function isStoreAccessor(callee) {
      if (callee.name.endsWith("Store")) {
        return true;
      }
      return Boolean(services?.getTypeAtLocation(callee).getProperty("$id"));
    }
    return {
      "CallExpression[callee.type='Identifier']"(node) {
        const name = node.callee.name;
        if (!COMPOSABLE.test(name)) {
          return;
        }
        const fn = enclosingFunction(node);
        if (!fn && !isVue) {
          context.report({ node, messageId: "moduleScope", data: { name } });
          return;
        }
        if (isStoreAccessor(node.callee)) {
          return;
        }
        if (fn && !isSetupFunction(fn)) {
          context.report({ node, messageId: "nested", data: { name } });
          return;
        }
        if (conditionalAncestor(node, fn ?? null)) {
          context.report({ node, messageId: "conditional", data: { name } });
        }
      },
    };
  },
});
