import { createRule } from "../ast.mjs";

const KEEP = /^\s*(?:!|\/\s*<|eslint|global\s|globals\s|@ts-|@license|@preserve|@vitest-environment|@jest-environment|@jsx|#__|copyright|spdx-license)/i;

export default createRule({
  name: "no-file-header-comment",
  meta: {
    type: "suggestion",
    docs: { description: "Disallow a comment at the top of a file that describes the file rather than the declaration below it" },
    messages: {
      header: "File header comment: drop it; the module's name and exports describe it.",
    },
    schema: [],
  },
  defaultOptions: [],
  create(context) {
    const source = context.sourceCode;
    return {
      Program(node) {
        const [comment] = source.getAllComments();
        if (!comment || KEEP.test(comment.value)) {
          return;
        }
        const first = source.ast.tokens[0];
        if (!first || comment.range[0] > first.range[0] || node.body.length === 0) {
          return;
        }
        const documentsDeclaration =
          node.body[0].type !== "ImportDeclaration" && first.loc.start.line === comment.loc.end.line + 1;
        if (documentsDeclaration) {
          return;
        }
        context.report({ loc: comment.loc, messageId: "header" });
      },
    };
  },
});
