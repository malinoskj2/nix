use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_hir::def_id::LocalDefId;
use rustc_hir::intravisit::FnKind;
use rustc_attr_ir::lang_items::LangItem;
use rustc_hir::{Body, FnDecl, FnRetTy, Node};
use rustc_lint::{LateContext, LateLintPass};
use rustc_middle::ty::{self, GenericArgKind, Ty};
use dylint_linting::{declare_lint, declare_lint_pass};
use clippy_utils::sym;
use rustc_span::Span;

declare_lint! {
    /// ### What it does
    /// Flags a function returning `Result<_, String>`, `Result<_, &str>` or
    /// `Result<_, Box<dyn Error>>`.
    ///
    /// ### Why is this bad?
    /// String errors cannot be matched and lose the cause chain; a boxed `dyn Error` erases the
    /// type without `anyhow`'s context. Return a `thiserror` type, or `anyhow::Result` at a
    /// report-only boundary.
    pub STRINGLY_ERROR,
    Warn,
    "function returns a string or boxed `dyn Error` as its error type"
}

declare_lint_pass!(StringlyError => [STRINGLY_ERROR]);

fn describe<'tcx>(cx: &LateContext<'tcx>, err: Ty<'tcx>) -> Option<&'static str> {
    if err
        .ty_adt_def()
        .is_some_and(|adt| cx.tcx.lang_items().get(LangItem::String) == Some(adt.did()))
    {
        return Some("String");
    }
    if let ty::Ref(_, inner, _) = err.kind()
        && inner.is_str()
    {
        return Some("&str");
    }
    if err.is_box()
        && let ty::Dynamic(preds, ..) = err.expect_boxed_ty().kind()
        && preds
            .principal_def_id()
            .is_some_and(|id| cx.tcx.is_diagnostic_item(sym::Error, id))
    {
        return Some("Box<dyn Error>");
    }
    None
}

impl<'tcx> LateLintPass<'tcx> for StringlyError {
    fn check_fn(
        &mut self,
        cx: &LateContext<'tcx>,
        kind: FnKind<'tcx>,
        decl: &'tcx FnDecl<'tcx>,
        _: &'tcx Body<'tcx>,
        span: Span,
        def_id: LocalDefId,
    ) {
        if matches!(kind, FnKind::Closure) || span.from_expansion() {
            return;
        }
        let FnRetTy::Return(ret_ty) = decl.output else {
            return;
        };
        let hir_id = cx.tcx.local_def_id_to_hir_id(def_id);
        if is_in_test(cx.tcx, hir_id) {
            return;
        }
        if let Node::ImplItem(item) = cx.tcx.hir_node(hir_id)
            && let rustc_hir::ImplItemImplKind::Trait { .. } = item.impl_kind
        {
            return;
        }
        let output = cx.tcx.fn_sig(def_id).instantiate_identity().skip_binder().output();
        let ty::Adt(adt, args) = output.kind() else {
            return;
        };
        if !cx.tcx.is_diagnostic_item(sym::Result, adt.did()) {
            return;
        }
        let Some(GenericArgKind::Type(err)) = args.get(1).map(|arg| arg.kind()) else {
            return;
        };
        if let Some(name) = describe(cx, err) {
            span_lint_and_help(
                cx,
                STRINGLY_ERROR,
                ret_ty.span,
                format!("`{name}` used as an error type"),
                None,
                "return a `thiserror` error, or `anyhow::Result` where the caller only reports failure",
            );
        }
    }
}
