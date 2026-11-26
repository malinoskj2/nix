use clippy_utils::diagnostics::span_lint_and_help;
use rustc_ast::{Item, ItemKind};
use rustc_lint::{EarlyContext, EarlyLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

declare_lint! {
    /// ### What it does
    /// Flags modules named `utils`, `util`, `helpers`, `helper`, `misc`, `constants` or `consts`.
    ///
    /// ### Why is this bad?
    /// Catch-all modules collect code by kind instead of by the domain responsibility that owns
    /// it. Keep helpers, types and constants with the feature that uses them.
    pub CATCH_ALL_MODULE,
    Warn,
    "module named as a catch-all instead of by responsibility"
}

declare_lint_pass!(CatchAllModule => [CATCH_ALL_MODULE]);

const NAMES: &[&str] = &["utils", "util", "helpers", "helper", "misc", "constants", "consts"];

impl EarlyLintPass for CatchAllModule {
    fn check_item(&mut self, cx: &EarlyContext<'_>, item: &Item) {
        if let ItemKind::Mod(_, ident, _) = item.kind
            && !item.span.from_expansion()
            && NAMES.contains(&ident.as_str())
        {
            span_lint_and_help(
                cx,
                CATCH_ALL_MODULE,
                ident.span,
                format!("catch-all module `{ident}`"),
                None,
                "move each item to the module that owns its responsibility",
            );
        }
    }
}
