use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_hir::{Expr, ExprKind, MatchSource, PatKind};
use rustc_lint::{LateContext, LateLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

declare_lint! {
    /// ### What it does
    /// Flags a `_` or catch-all binding arm in a `match` on an enum defined in the current crate.
    ///
    /// ### Why is this bad?
    /// A wildcard silently absorbs variants added later, so decisions that depend on the variant
    /// are never revisited. Listing the variants makes the compiler point at every such match.
    ///
    /// ### Example
    /// ```rust
    /// enum State { Idle, Running, Paused }
    /// fn busy(state: &State) -> bool {
    ///     match state {
    ///         State::Running => true,
    ///         _ => false,
    ///     }
    /// }
    /// ```
    /// Use instead: list `State::Idle | State::Paused => false`.
    pub LOCAL_ENUM_WILDCARD_ARM,
    Warn,
    "wildcard arm in a match on a local enum"
}

declare_lint_pass!(LocalEnumWildcardArm => [LOCAL_ENUM_WILDCARD_ARM]);

impl<'tcx> LateLintPass<'tcx> for LocalEnumWildcardArm {
    fn check_expr(&mut self, cx: &LateContext<'tcx>, expr: &'tcx Expr<'tcx>) {
        let ExprKind::Match(scrutinee, arms, MatchSource::Normal) = expr.kind else {
            return;
        };
        if expr.span.from_expansion() || is_in_test(cx.tcx, expr.hir_id) {
            return;
        }
        let ty = cx.typeck_results().expr_ty(scrutinee).peel_refs();
        let Some(adt) = ty.ty_adt_def() else {
            return;
        };
        if !adt.is_enum() || !adt.did().is_local() || adt.variants().len() < 2 {
            return;
        }
        for arm in arms {
            let catch_all = match arm.pat.kind {
                PatKind::Wild => true,
                PatKind::Binding(_, _, _, None) => true,
                _ => false,
            };
            if catch_all && arm.guard.is_none() && !arm.pat.span.from_expansion() {
                span_lint_and_help(
                    cx,
                    LOCAL_ENUM_WILDCARD_ARM,
                    arm.pat.span,
                    format!("wildcard arm in a match on `{ty}`"),
                    None,
                    "list the remaining variants so a new variant forces this decision to be revisited",
                );
            }
        }
    }
}
