import path from "node:path";
import { createRule } from "../ast.mjs";

const NAMES = new Set(["utils", "util", "helpers", "helper", "misc", "common", "constants", "consts"]);

export default createRule({
  name: "no-catch-all-module",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow modules and directories named as catch-alls instead of by responsibility" },
    messages: {
      catchAll: "Catch-all module `{{name}}`: move each item to the module that owns its responsibility.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      Program(node) {
        const file = path.parse(context.filename);
        const name = file.name.replace(/\.(d|test|spec)$/, "");
        const owner = name === "index" ? path.basename(file.dir) : name;
        const directory = path.basename(file.dir);
        const match = [owner, directory].find((candidate) => NAMES.has(candidate));
        if (match) {
          context.report({ node, loc: { line: 1, column: 0 }, messageId: "catchAll", data: { name: match } });
        }
      },
    };
  },
});
