use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_hir::{Expr, ExprKind, LetStmt, PatKind, Stmt, StmtKind};
use rustc_lint::{LateContext, LateLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

use crate::paths;

declare_lint! {
    /// ### What it does
    /// Flags a thread or task spawn whose handle is dropped at once, as a statement or bound to
    /// `_`. Covers `std::thread::spawn` and the free `spawn`, `spawn_local` and `spawn_blocking`
    /// functions of tokio, async-std and smol.
    ///
    /// ### Why is this bad?
    /// Nothing owns the task: nobody joins it, observes its failure or stops it on shutdown.
    ///
    /// ### Example
    /// ```rust
    /// std::thread::spawn(|| work());
    /// ```
    /// Keep the handle with the owner that joins it, or use a `JoinSet`.
    pub DETACHED_SPAWN,
    Warn,
    "spawned thread or task whose handle is discarded"
}

declare_lint_pass!(DetachedSpawn => [DETACHED_SPAWN]);

fn spawn_name(cx: &LateContext<'_>, expr: &Expr<'_>) -> Option<String> {
    let ExprKind::Call(..) = expr.kind else {
        return None;
    };
    let def_id = paths::callee(cx, expr)?;
    if !paths::is_free_fn(cx, def_id) {
        return None;
    }
    let krate = paths::crate_name(cx, def_id);
    let name = paths::item_name(cx, def_id);
    let path = cx.get_def_path(def_id);
    let matched = match krate.as_str() {
        "std" => name == "spawn" && path.iter().any(|segment| segment.as_str() == "thread"),
        "tokio" | "async_std" | "smol" | "async_global_executor" => {
            matches!(name.as_str(), "spawn" | "spawn_local" | "spawn_blocking")
        }
        _ => false,
    };
    matched.then(|| paths::path(cx, def_id))
}

fn report(cx: &LateContext<'_>, expr: &Expr<'_>) {
    if expr.span.from_expansion() || is_in_test(cx.tcx, expr.hir_id) {
        return;
    }
    if let Some(path) = spawn_name(cx, expr) {
        span_lint_and_help(
            cx,
            DETACHED_SPAWN,
            expr.span,
            format!("the handle returned by `{path}` is discarded"),
            None,
            "keep the handle with an owner that joins or aborts it on shutdown",
        );
    }
}

impl<'tcx> LateLintPass<'tcx> for DetachedSpawn {
    fn check_stmt(&mut self, cx: &LateContext<'tcx>, stmt: &'tcx Stmt<'tcx>) {
        if let StmtKind::Semi(expr) = stmt.kind {
            report(cx, expr);
        }
    }

    fn check_local(&mut self, cx: &LateContext<'tcx>, local: &'tcx LetStmt<'tcx>) {
        if let PatKind::Wild = local.pat.kind
            && let Some(init) = local.init
        {
            report(cx, init);
        }
    }
}
