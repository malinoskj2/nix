import { ESLintUtils } from "@typescript-eslint/utils";

export const createRule = ESLintUtils.RuleCreator(
  (name) => `https://github.com/malinoskj2/nix/blob/main/pkgs/ts-lints/plugin/rules/${name}.mjs`,
);

export function typeServices(context) {
  const services = context.sourceCode.parserServices;
  return services?.program ? services : null;
}

export function templateVisitor(context, template, script = {}) {
  const services = context.sourceCode.parserServices;
  if (!services?.defineTemplateBodyVisitor) {
    return script;
  }
  return services.defineTemplateBodyVisitor(template, script);
}

export function importedFrom(context, sources) {
  const names = new Map();
  for (const statement of context.sourceCode.ast.body) {
    if (statement.type !== "ImportDeclaration" || !sources.includes(statement.source.value)) {
      continue;
    }
    for (const specifier of statement.specifiers) {
      if (specifier.type === "ImportSpecifier") {
        const imported = specifier.imported.type === "Identifier" ? specifier.imported.name : specifier.imported.value;
        names.set(specifier.local.name, imported);
      }
    }
  }
  return names;
}

export function identifiersIn(node, found = new Set()) {
  if (!node || typeof node.type !== "string") {
    return found;
  }
  if (node.type === "Identifier") {
    found.add(node.name);
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === "parent" || key === "range" || key === "loc") {
      continue;
    }
    if (Array.isArray(value)) {
      for (const child of value) {
        identifiersIn(child, found);
      }
    } else if (value && typeof value.type === "string") {
      if (node.type === "MemberExpression" && key === "property" && !node.computed) {
        continue;
      }
      identifiersIn(value, found);
    }
  }
  return found;
}

export function enclosingFunction(node) {
  for (let current = node.parent; current; current = current.parent) {
    if (
      current.type === "FunctionDeclaration" ||
      current.type === "FunctionExpression" ||
      current.type === "ArrowFunctionExpression"
    ) {
      return current;
    }
  }
  return null;
}

export function functionName(fn) {
  if (fn.id) {
    return fn.id.name;
  }
  const parent = fn.parent;
  if (parent.type === "VariableDeclarator" && parent.id.type === "Identifier") {
    return parent.id.name;
  }
  if ((parent.type === "Property" || parent.type === "MethodDefinition") && parent.key.type === "Identifier") {
    return parent.key.name;
  }
  return null;
}

export function calleeName(call) {
  const callee = call.callee;
  if (callee.type === "Identifier") {
    return callee.name;
  }
  if (callee.type === "MemberExpression" && !callee.computed && callee.property.type === "Identifier") {
    return callee.property.name;
  }
  return null;
}
