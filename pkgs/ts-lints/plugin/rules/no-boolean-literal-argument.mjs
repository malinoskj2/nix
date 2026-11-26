import { calleeName, createRule, typeServices } from "../ast.mjs";

function isLocalDeclaration(services, declaration) {
  const file = declaration?.getSourceFile();
  if (!file || file.isDeclarationFile) {
    return false;
  }
  const program = services.program;
  return !program.isSourceFileFromExternalLibrary(file) && !program.isSourceFileDefaultLibrary(file);
}

export default createRule({
  name: "no-boolean-literal-argument",
  meta: {
    type: "suggestion",
    docs: {
      description: "Disallow a boolean literal argument to a function defined in this project",
      requiresTypeChecking: true,
    },
    messages: {
      literal: "`{{value}}` does not say what it selects: take a string-literal union or an options object instead.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    const services = typeServices(context);
    if (!services) {
      return {};
    }
    const checker = services.program.getTypeChecker();
    function check(node) {
      const literals = node.arguments.filter((arg) => arg.type === "Literal" && typeof arg.value === "boolean");
      if (literals.length === 0) {
        return;
      }
      const name = calleeName(node);
      if (name && /^(set|with)[A-Z_]/.test(name)) {
        return;
      }
      const signature = checker.getResolvedSignature(services.esTreeNodeToTSNodeMap.get(node));
      if (!isLocalDeclaration(services, signature?.getDeclaration())) {
        return;
      }
      for (const literal of literals) {
        context.report({ node: literal, messageId: "literal", data: { value: String(literal.value) } });
      }
    }
    return { CallExpression: check, NewExpression: check };
  },
});
