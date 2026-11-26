use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_hir::{Item, ItemKind};
use rustc_lint::{LateContext, LateLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};
use clippy_utils::sym;

declare_lint! {
    /// ### What it does
    /// Flags a hand-written `impl std::error::Error`.
    ///
    /// ### Why is this bad?
    /// Error types derive `thiserror::Error`, which writes `Display`, `Error` and `source`
    /// consistently from the variant attributes.
    pub MANUAL_ERROR_IMPL,
    Warn,
    "hand-written `std::error::Error` impl instead of `thiserror`"
}

declare_lint_pass!(ManualErrorImpl => [MANUAL_ERROR_IMPL]);

impl<'tcx> LateLintPass<'tcx> for ManualErrorImpl {
    fn check_item(&mut self, cx: &LateContext<'tcx>, item: &'tcx Item<'tcx>) {
        if let ItemKind::Impl(impl_) = item.kind
            && let Some(header) = impl_.of_trait
            && !item.span.from_expansion()
            && let Some(trait_id) = header.trait_ref.trait_def_id()
            && cx.tcx.is_diagnostic_item(sym::Error, trait_id)
            && !is_in_test(cx.tcx, item.hir_id())
        {
            span_lint_and_help(
                cx,
                MANUAL_ERROR_IMPL,
                item.span,
                "hand-written `Error` impl",
                None,
                "derive `thiserror::Error` and describe each variant with `#[error(...)]`",
            );
        }
    }
}
