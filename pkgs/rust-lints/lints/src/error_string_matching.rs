use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use clippy_utils::ty::implements_trait;
use rustc_hir::{BinOpKind, Expr, ExprKind};
use rustc_lint::{LateContext, LateLintPass};
use rustc_middle::ty::Ty;
use dylint_linting::{declare_lint, declare_lint_pass};
use clippy_utils::sym;

use crate::paths;

declare_lint! {
    /// ### What it does
    /// Flags string inspection of an error's rendered message: `contains`, `starts_with`,
    /// `ends_with`, `find`, `matches` or `==` on `err.to_string()`.
    ///
    /// ### Why is this bad?
    /// Messages are for people and change freely. Callers that choose policy by failure kind
    /// need a typed error to match on.
    ///
    /// ### Example
    /// ```rust
    /// if err.to_string().contains("not found") {}
    /// ```
    /// Use instead: match the error's variant or `io::ErrorKind`.
    pub ERROR_STRING_MATCHING,
    Warn,
    "control flow decided by an error's message text"
}

declare_lint_pass!(ErrorStringMatching => [ERROR_STRING_MATCHING]);

const INSPECTIONS: &[&str] = &["contains", "starts_with", "ends_with", "find", "matches", "eq", "ne"];

fn is_error_type<'tcx>(cx: &LateContext<'tcx>, ty: Ty<'tcx>) -> bool {
    let ty = ty.peel_refs();
    if let Some(adt) = ty.ty_adt_def() {
        let krate = paths::crate_name(cx, adt.did());
        let name = paths::item_name(cx, adt.did());
        if (krate == "anyhow" && name == "Error") || (krate == "eyre" && name == "Report") {
            return true;
        }
    }
    let ty = if ty.is_box() { ty.expect_boxed_ty() } else { ty };
    cx.tcx
        .get_diagnostic_item(sym::Error)
        .is_some_and(|error| implements_trait(cx, ty, error, &[]))
}

fn rendered_error<'tcx>(cx: &LateContext<'tcx>, expr: &'tcx Expr<'tcx>) -> bool {
    let mut expr = expr;
    loop {
        match expr.kind {
            ExprKind::AddrOf(_, _, inner) | ExprKind::Unary(_, inner) => expr = inner,
            ExprKind::MethodCall(segment, receiver, [], _)
                if matches!(segment.ident.as_str(), "as_str" | "as_ref" | "to_lowercase") =>
            {
                expr = receiver;
            }
            ExprKind::MethodCall(segment, receiver, [], _) if segment.ident.as_str() == "to_string" => {
                return is_error_type(cx, cx.typeck_results().expr_ty(receiver));
            }
            _ => return false,
        }
    }
}

fn report(cx: &LateContext<'_>, expr: &Expr<'_>) {
    span_lint_and_help(
        cx,
        ERROR_STRING_MATCHING,
        expr.span,
        "control flow inspects an error's message text",
        None,
        "match a typed error variant or kind instead",
    );
}

impl<'tcx> LateLintPass<'tcx> for ErrorStringMatching {
    fn check_expr(&mut self, cx: &LateContext<'tcx>, expr: &'tcx Expr<'tcx>) {
        if expr.span.from_expansion() || is_in_test(cx.tcx, expr.hir_id) {
            return;
        }
        match expr.kind {
            ExprKind::MethodCall(segment, receiver, _, _)
                if INSPECTIONS.contains(&segment.ident.as_str()) && rendered_error(cx, receiver) =>
            {
                report(cx, expr);
            }
            ExprKind::Binary(op, left, right)
                if matches!(op.node, BinOpKind::Eq | BinOpKind::Ne)
                    && (rendered_error(cx, left) || rendered_error(cx, right)) =>
            {
                report(cx, expr);
            }
            _ => {}
        }
    }
}
