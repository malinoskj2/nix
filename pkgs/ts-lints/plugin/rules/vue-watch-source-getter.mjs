import ts from "typescript";
import { createRule, importedFrom, typeServices } from "../ast.mjs";

const PRIMITIVE =
  ts.TypeFlags.StringLike |
  ts.TypeFlags.NumberLike |
  ts.TypeFlags.BooleanLike |
  ts.TypeFlags.BigIntLike |
  ts.TypeFlags.EnumLike |
  ts.TypeFlags.Null |
  ts.TypeFlags.Undefined;

function isPrimitive(type) {
  if (type.isUnion()) {
    return type.types.every(isPrimitive);
  }
  return (type.flags & PRIMITIVE) !== 0;
}

function isPlainMember(node) {
  return (
    node.type === "MemberExpression" &&
    !(node.property.type === "Identifier" && !node.computed && node.property.name === "value")
  );
}

export default createRule({
  name: "vue-watch-source-getter",
  meta: {
    type: "problem",
    docs: { description: "Require a getter when watching a property of props, a store or another reactive object" },
    messages: {
      getter: "`watch` receives the current value of `{{source}}`, not a reactive source: pass `() => {{source}}`.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    const services = typeServices(context);
    let imports = null;
    function isStaticValue(node) {
      if (!isPlainMember(node)) {
        return false;
      }
      if (services) {
        return isPrimitive(services.getTypeAtLocation(node));
      }
      return node.object.type === "Identifier" && node.object.name === "props";
    }
    return {
      "CallExpression[callee.type='Identifier']"(node) {
        imports ??= importedFrom(context, ["vue"]);
        if (imports.get(node.callee.name) !== "watch") {
          return;
        }
        const [source] = node.arguments;
        if (!source) {
          return;
        }
        const candidates = source.type === "ArrayExpression" ? source.elements : [source];
        for (const candidate of candidates) {
          if (candidate && isStaticValue(candidate)) {
            const text = context.sourceCode.getText(candidate);
            context.report({ node: candidate, messageId: "getter", data: { source: text } });
          }
        }
      },
    };
  },
});
