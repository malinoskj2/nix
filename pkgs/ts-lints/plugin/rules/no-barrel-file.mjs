import fs from "node:fs";
import path from "node:path";
import { createRule } from "../ast.mjs";

function isPackageEntry(file) {
  const directory = path.dirname(file);
  const candidates = [directory, path.basename(directory) === "src" ? path.dirname(directory) : null];
  return candidates.some((candidate) => candidate && fs.existsSync(path.join(candidate, "package.json")));
}

function isReExport(statement) {
  return (
    statement.type === "ExportAllDeclaration" ||
    (statement.type === "ExportNamedDeclaration" && statement.source !== null)
  );
}

export default createRule({
  name: "no-barrel-file",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow index files that only re-export other modules, outside a package entry" },
    messages: {
      barrel: "Barrel file: import from the module that defines each export instead of re-exporting it here.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    return {
      Program(node) {
        if (!/^index\.[cm]?[jt]sx?$/.test(path.basename(context.filename))) {
          return;
        }
        if (node.body.length === 0 || !node.body.every(isReExport) || isPackageEntry(context.filename)) {
          return;
        }
        context.report({ node: node.body[0], messageId: "barrel" });
      },
    };
  },
});
