use clippy_utils::diagnostics::span_lint_and_help;
use clippy_utils::is_in_test;
use rustc_hir::{CoroutineDesugaring, CoroutineKind, Expr};
use rustc_lint::{LateContext, LateLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

use crate::paths;

declare_lint! {
    /// ### What it does
    /// Flags a blocking standard-library or `reqwest::blocking` call made directly in an async
    /// body.
    ///
    /// ### Why is this bad?
    /// It stalls the executor thread and every task scheduled on it.
    ///
    /// ### Example
    /// ```rust
    /// async fn load() -> std::io::Result<String> {
    ///     std::fs::read_to_string("state.json")
    /// }
    /// ```
    /// Use the runtime's async API or `spawn_blocking`.
    pub BLOCKING_CALL_IN_ASYNC,
    Warn,
    "blocking call directly inside an async body"
}

declare_lint_pass!(BlockingCallInAsync => [BLOCKING_CALL_IN_ASYNC]);

const STD_FS_FNS: &[&str] = &[
    "canonicalize",
    "copy",
    "create_dir",
    "create_dir_all",
    "hard_link",
    "metadata",
    "read",
    "read_dir",
    "read_link",
    "read_to_string",
    "remove_dir",
    "remove_dir_all",
    "remove_file",
    "rename",
    "set_permissions",
    "symlink_metadata",
    "write",
];

const STD_BLOCKING_METHODS: &[(&str, &str)] = &[
    ("File", "create"),
    ("File", "open"),
    ("Command", "output"),
    ("Command", "status"),
    ("Child", "wait"),
    ("Child", "wait_with_output"),
    ("JoinHandle", "join"),
    ("Receiver", "recv"),
    ("TcpStream", "connect"),
    ("TcpListener", "accept"),
];

fn blocking_call(cx: &LateContext<'_>, expr: &Expr<'_>) -> Option<String> {
    let def_id = paths::callee(cx, expr)?;
    let krate = paths::crate_name(cx, def_id);
    let segments = cx.get_def_path(def_id);
    let names: Vec<String> = segments.iter().map(ToString::to_string).collect();
    let name = names.last()?.as_str();

    let blocking = match krate.as_str() {
        "std" if paths::is_free_fn(cx, def_id) => {
            (names.get(1).map(String::as_str) == Some("fs") && STD_FS_FNS.contains(&name))
                || (names.get(1).map(String::as_str) == Some("thread") && name == "sleep")
        }
        "std" => names.len() >= 2 && {
            let owner = names[names.len() - 2].as_str();
            STD_BLOCKING_METHODS.contains(&(owner, name))
        },
        "reqwest" => names.iter().any(|segment| segment == "blocking"),
        _ => false,
    };
    blocking.then(|| paths::path(cx, def_id))
}

fn in_async_body(cx: &LateContext<'_>, expr: &Expr<'_>) -> bool {
    let owner = cx.tcx.hir_enclosing_body_owner(expr.hir_id);
    matches!(
        cx.tcx.coroutine_kind(owner),
        Some(CoroutineKind::Desugared(CoroutineDesugaring::Async, _))
    )
}

impl<'tcx> LateLintPass<'tcx> for BlockingCallInAsync {
    fn check_expr(&mut self, cx: &LateContext<'tcx>, expr: &'tcx Expr<'tcx>) {
        if expr.span.from_expansion() || !in_async_body(cx, expr) || is_in_test(cx.tcx, expr.hir_id) {
            return;
        }
        if let Some(path) = blocking_call(cx, expr) {
            span_lint_and_help(
                cx,
                BLOCKING_CALL_IN_ASYNC,
                expr.span,
                format!("blocking call to `{path}` inside an async body"),
                None,
                "use the runtime's async equivalent or move the work into `spawn_blocking`",
            );
        }
    }
}
