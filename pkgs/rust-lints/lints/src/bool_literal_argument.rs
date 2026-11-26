use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_ast::LitKind;
use rustc_hir::def::DefKind;
use rustc_hir::{Expr, ExprKind};
use rustc_lint::{LateContext, LateLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

use crate::paths;

declare_lint! {
    /// ### What it does
    /// Flags a `true` or `false` literal passed to a function or method defined in the current
    /// crate.
    ///
    /// ### Why is this bad?
    /// `render(true)` does not say what `true` selects. A two-variant enum names the choice at
    /// the call site.
    ///
    /// Setters and builders (`set_*`, `with_*`) are exempt, since their name states the meaning.
    ///
    /// ### Example
    /// ```rust
    /// fn render(compact: bool) {}
    /// render(true);
    /// ```
    /// Use instead:
    /// ```rust
    /// enum Layout { Compact, Full }
    /// fn render(layout: Layout) {}
    /// render(Layout::Compact);
    /// ```
    pub BOOL_LITERAL_ARGUMENT,
    Warn,
    "boolean literal passed to a local function"
}

declare_lint_pass!(BoolLiteralArgument => [BOOL_LITERAL_ARGUMENT]);

impl<'tcx> LateLintPass<'tcx> for BoolLiteralArgument {
    fn check_expr(&mut self, cx: &LateContext<'tcx>, expr: &'tcx Expr<'tcx>) {
        let args = match expr.kind {
            ExprKind::Call(_, args) | ExprKind::MethodCall(_, _, args, _) => args,
            _ => return,
        };
        if expr.span.from_expansion() {
            return;
        }
        let Some(def_id) = paths::callee(cx, expr) else {
            return;
        };
        if !def_id.is_local()
            || !matches!(cx.tcx.def_kind(def_id), DefKind::Fn | DefKind::AssocFn)
        {
            return;
        }
        let name = paths::item_name(cx, def_id);
        if name.starts_with("set_") || name.starts_with("with_") || is_in_test(cx.tcx, expr.hir_id) {
            return;
        }
        for arg in args {
            if let ExprKind::Lit(lit) = arg.kind
                && let LitKind::Bool(value) = lit.node
                && !arg.span.from_expansion()
            {
                span_lint_and_help(
                    cx,
                    BOOL_LITERAL_ARGUMENT,
                    arg.span,
                    format!("`{value}` passed to `{name}` does not say what it selects"),
                    None,
                    "take a two-variant enum that names the choice",
                );
            }
        }
    }
}
