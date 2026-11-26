import { createRule } from "../ast.mjs";

function propertyNamed(object, name) {
  return object.properties.find(
    (property) =>
      property.type === "Property" &&
      !property.computed &&
      ((property.key.type === "Identifier" && property.key.name === name) || property.key.value === name),
  );
}

export default createRule({
  name: "vue-lazy-route-component",
  meta: {
    type: "suggestion",
    docs: { description: "Require route components to be loaded lazily" },
    messages: {
      eager: "Route component `{{name}}` is imported eagerly: use `component: () => import('{{source}}')`.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    let vueImports = null;
    function eagerImports() {
      if (vueImports) {
        return vueImports;
      }
      vueImports = new Map();
      for (const statement of context.sourceCode.ast.body) {
        if (statement.type !== "ImportDeclaration" || !String(statement.source.value).endsWith(".vue")) {
          continue;
        }
        for (const specifier of statement.specifiers) {
          if (specifier.type === "ImportDefaultSpecifier") {
            vueImports.set(specifier.local.name, statement.source.value);
          }
        }
      }
      return vueImports;
    }
    return {
      ObjectExpression(node) {
        const component = propertyNamed(node, "component");
        if (!component || component.value.type !== "Identifier" || !propertyNamed(node, "path")) {
          return;
        }
        const source = eagerImports().get(component.value.name);
        if (source) {
          context.report({ node: component.value, messageId: "eager", data: { name: component.value.name, source } });
        }
      },
    };
  },
});
