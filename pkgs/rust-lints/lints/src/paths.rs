use rustc_hir::def::DefKind;
use rustc_hir::def_id::DefId;
use rustc_hir::{Expr, ExprKind};
use rustc_lint::LateContext;

pub fn callee(cx: &LateContext<'_>, expr: &Expr<'_>) -> Option<DefId> {
    match expr.kind {
        ExprKind::Call(func, _) => clippy_utils::fn_def_id(cx, expr).or_else(|| {
            if let ExprKind::Path(qpath) = &func.kind {
                cx.qpath_res(qpath, func.hir_id).opt_def_id()
            } else {
                None
            }
        }),
        ExprKind::MethodCall(..) => cx.typeck_results().type_dependent_def_id(expr.hir_id),
        _ => None,
    }
}

pub fn crate_name(cx: &LateContext<'_>, def_id: DefId) -> String {
    cx.tcx.crate_name(def_id.krate).to_string()
}

pub fn item_name(cx: &LateContext<'_>, def_id: DefId) -> String {
    cx.tcx.item_name(def_id).to_string()
}

pub fn path(cx: &LateContext<'_>, def_id: DefId) -> String {
    cx.tcx.def_path_str(def_id)
}

pub fn is_free_fn(cx: &LateContext<'_>, def_id: DefId) -> bool {
    cx.tcx.def_kind(def_id) == DefKind::Fn
}
