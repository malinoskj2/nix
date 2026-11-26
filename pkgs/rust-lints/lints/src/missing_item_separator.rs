use clippy_utils::diagnostics::span_lint_and_help;
use rustc_ast::{AssocItem, AssocItemKind, Crate, Inline, Item, ItemKind, ModKind};
use rustc_lint::{EarlyContext, EarlyLintPass, LintContext};
use dylint_linting::{declare_lint, declare_lint_pass};
use rustc_span::Span;

declare_lint! {
    /// ### What it does
    /// Flags two adjacent items with no empty line between them, unless both are groupable
    /// declarations: `use`, `extern crate`, `mod name;`, `const`, `static`, `type`, or trait
    /// methods without a body.
    ///
    /// ### Why is this bad?
    /// Functions, methods, types and impls are separated by exactly one empty line. rustfmt
    /// collapses extra empty lines but never inserts a missing one.
    ///
    /// ### Example
    /// ```rust
    /// fn first() {}
    /// fn second() {}
    /// ```
    pub MISSING_ITEM_SEPARATOR,
    Warn,
    "adjacent items without an empty line between them"
}

declare_lint_pass!(MissingItemSeparator => [MISSING_ITEM_SEPARATOR]);

struct Entry {
    span: Span,
    start: Span,
    groupable: bool,
    describe: &'static str,
}

fn item_entry(item: &Item) -> Entry {
    let (groupable, describe) = match &item.kind {
        ItemKind::Use(_) => (true, "import"),
        ItemKind::ExternCrate(..) => (true, "extern crate"),
        ItemKind::Mod(_, _, ModKind::Loaded(_, Inline::No { .. }, _) | ModKind::Unloaded) => {
            (true, "module declaration")
        }
        ItemKind::Const(_) => (true, "constant"),
        ItemKind::Static(_) => (true, "static"),
        ItemKind::TyAlias(_) => (true, "type alias"),
        kind => (false, kind.descr()),
    };
    Entry {
        span: item.span,
        start: item.span_with_attributes(),
        groupable,
        describe,
    }
}

fn assoc_entry(item: &AssocItem) -> Entry {
    let (groupable, describe) = match &item.kind {
        AssocItemKind::Fn(function) => (function.body.is_none(), "method"),
        AssocItemKind::Const(_) => (true, "associated constant"),
        AssocItemKind::Type(_) => (true, "associated type"),
        _ => (false, "associated item"),
    };
    let start = item
        .attrs
        .iter()
        .fold(item.span, |span, attr| span.to(attr.span));
    Entry {
        span: item.span,
        start,
        groupable,
        describe,
    }
}

fn has_empty_line(gap: &str) -> bool {
    let mut lines = gap.split('\n');
    lines.next();
    let mut lines: Vec<&str> = lines.collect();
    lines.pop();
    lines.iter().any(|line| line.trim().is_empty())
}

fn check(cx: &EarlyContext<'_>, entries: impl Iterator<Item = Entry>) {
    let mut previous: Option<Entry> = None;
    for entry in entries {
        if entry.span.from_expansion() || entry.span.is_dummy() {
            previous = None;
            continue;
        }
        if let Some(prev) = &previous
            && !(prev.groupable && entry.groupable)
            && prev.span.ctxt() == entry.start.ctxt()
            && prev.span.hi() <= entry.start.lo()
        {
            let gap = prev.span.between(entry.start);
            if let Ok(text) = cx.sess().source_map().span_to_snippet(gap)
                && text.contains('\n')
                && !has_empty_line(&text)
            {
                span_lint_and_help(
                    cx,
                    MISSING_ITEM_SEPARATOR,
                    entry.start.shrink_to_lo(),
                    format!(
                        "{} placed directly against the previous {}",
                        entry.describe, prev.describe
                    ),
                    None,
                    "separate the items with one empty line",
                );
            }
        }
        previous = Some(entry);
    }
}

impl EarlyLintPass for MissingItemSeparator {
    fn check_crate(&mut self, cx: &EarlyContext<'_>, krate: &Crate) {
        check(cx, krate.items.iter().map(|item| item_entry(item)));
    }

    fn check_item(&mut self, cx: &EarlyContext<'_>, item: &Item) {
        if item.span.from_expansion() {
            return;
        }
        match &item.kind {
            ItemKind::Mod(_, _, ModKind::Loaded(items, _, _)) => {
                check(cx, items.iter().map(|item| item_entry(item)));
            }
            ItemKind::Impl(impl_) => check(cx, impl_.items.iter().map(|item| assoc_entry(item))),
            ItemKind::Trait(trait_) => check(cx, trait_.items.iter().map(|item| assoc_entry(item))),
            _ => {}
        }
    }
}
