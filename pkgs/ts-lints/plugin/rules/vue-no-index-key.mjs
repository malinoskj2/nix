import { createRule, identifiersIn, templateVisitor } from "../ast.mjs";

function bindingName(pattern) {
  return pattern?.type === "Identifier" ? pattern.name : null;
}

function indexNames(forExpression) {
  const [value, second, third] = forExpression.left;
  const names = new Set();
  const position = bindingName(third);
  if (position) {
    names.add(position);
  }
  const index = bindingName(second);
  if (index && !third && !/key|id|name|prop/i.test(index)) {
    names.add(index);
  }
  return { names, value };
}

function keyExpression(element) {
  for (const attribute of element.startTag.attributes) {
    if (
      attribute.directive &&
      attribute.key.name.name === "bind" &&
      attribute.key.argument?.type === "VIdentifier" &&
      attribute.key.argument.name === "key"
    ) {
      return attribute.value?.expression ?? null;
    }
  }
  return null;
}

export default createRule({
  name: "vue-no-index-key",
  meta: {
    type: "problem",
    docs: { description: "Disallow keying v-for items by their position" },
    messages: {
      indexKey: "`:key` uses the v-for index `{{name}}`: key by a stable identity of the item.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return templateVisitor(context, {
      "VAttribute[directive=true][key.name.name='for']"(attribute) {
        const forExpression = attribute.value?.expression;
        if (forExpression?.type !== "VForExpression") {
          return;
        }
        const { names, value } = indexNames(forExpression);
        if (names.size === 0) {
          return;
        }
        const element = attribute.parent.parent;
        const targets = element.name === "template"
          ? element.children.filter((child) => child.type === "VElement")
          : [element];
        const valueNames = identifiersIn(value);
        for (const target of targets) {
          const key = keyExpression(target);
          if (!key) {
            continue;
          }
          const used = identifiersIn(key);
          const index = [...names].find((name) => used.has(name));
          const usesItem = [...valueNames].some((name) => used.has(name));
          if (index && !usesItem) {
            context.report({ node: key, messageId: "indexKey", data: { name: index } });
          }
        }
      },
    });
  },
});
