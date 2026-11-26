import { createRule, typeServices } from "../ast.mjs";

export default createRule({
  name: "vue-store-destructure",
  meta: {
    type: "problem",
    docs: {
      description: "Disallow destructuring a Pinia store's state or getters without storeToRefs",
      requiresTypeChecking: true,
    },
    messages: {
      lost: "Destructuring `{{name}}` from the store loses reactivity: use `storeToRefs()` for state and getters.",
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
    return {
      "VariableDeclarator[id.type='ObjectPattern'][init.type='CallExpression'][init.callee.type='Identifier']"(node) {
        if (!/^use\w*Store$/.test(node.init.callee.name)) {
          return;
        }
        const store = services.getTypeAtLocation(node.init);
        for (const property of node.id.properties) {
          if (property.type !== "Property" || property.computed || property.key.type !== "Identifier") {
            continue;
          }
          const member = store.getProperty(property.key.name);
          if (!member) {
            continue;
          }
          const type = checker.getTypeOfSymbolAtLocation(member, services.esTreeNodeToTSNodeMap.get(node.init));
          if (type.getCallSignatures().length === 0) {
            context.report({ node: property, messageId: "lost", data: { name: property.key.name } });
          }
        }
      },
    };
  },
});
