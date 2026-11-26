use clippy_utils::diagnostics::span_lint_and_help;
use rustc_ast::token::{LitKind, TokenKind};
use rustc_ast::tokenstream::TokenTree;
use rustc_ast::{AttrArgs, Attribute, FieldDef, Item, ItemKind, VariantData};
use rustc_lint::{EarlyContext, EarlyLintPass};
use dylint_linting::{declare_lint, declare_lint_pass};

declare_lint! {
    /// ### What it does
    /// Flags a `thiserror` `#[error("...")]` message that interpolates the variant's source:
    /// the field marked `#[from]` or `#[source]`, or named `source`.
    ///
    /// ### Why is this bad?
    /// The source is printed once when the chain is reported (`{:#}` on `anyhow::Error`, or a
    /// walk of `source()`). Repeating it in the message prints the cause twice.
    ///
    /// ### Example
    /// ```rust
    /// #[derive(Debug, thiserror::Error)]
    /// enum ConfigError {
    ///     #[error("failed to read config: {0}")]
    ///     Read(#[from] std::io::Error),
    /// }
    /// ```
    /// Use instead: `#[error("failed to read config")]`.
    pub THISERROR_SOURCE_IN_MESSAGE,
    Warn,
    "`#[error]` message repeats the error's source"
}

declare_lint_pass!(ThiserrorSourceInMessage => [THISERROR_SOURCE_IN_MESSAGE]);

fn has_attr(attrs: &[Attribute], name: &str) -> bool {
    attrs
        .iter()
        .any(|attr| attr.name().is_some_and(|attr_name| attr_name.as_str() == name))
}

fn source_names(data: &VariantData) -> Vec<String> {
    data.fields()
        .iter()
        .enumerate()
        .filter(|(_, field)| is_source(field))
        .map(|(index, field)| {
            field
                .ident
                .map_or_else(|| index.to_string(), |ident| ident.to_string())
        })
        .collect()
}

fn is_source(field: &FieldDef) -> bool {
    has_attr(&field.attrs, "from")
        || has_attr(&field.attrs, "source")
        || field.ident.is_some_and(|ident| ident.as_str() == "source")
}

fn format_arguments(template: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut chars = template.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '{' if chars.peek() == Some(&'{') => {
                chars.next();
            }
            '{' => {
                let name: String = chars
                    .by_ref()
                    .take_while(|c| *c != '}')
                    .collect::<String>()
                    .split(':')
                    .next()
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                names.push(name);
            }
            _ => {}
        }
    }
    names
}

fn interpolated(attr: &Attribute) -> Option<Vec<String>> {
    if !attr.name().is_some_and(|name| name.as_str() == "error") {
        return None;
    }
    let AttrArgs::Delimited(args) = &attr.get_normal_item().args else {
        return None;
    };
    let tokens: Vec<&TokenTree> = args.tokens.iter().collect();
    let TokenTree::Token(first, _) = tokens.first()? else {
        return None;
    };
    let TokenKind::Literal(lit) = first.kind else {
        return None;
    };
    if !matches!(lit.kind, LitKind::Str | LitKind::StrRaw(_)) {
        return None;
    }
    let mut names = format_arguments(lit.symbol.as_str());
    for pair in tokens.windows(2) {
        if let [TokenTree::Token(dot, _), TokenTree::Token(next, _)] = pair
            && dot.kind == TokenKind::Dot
        {
            match next.kind {
                TokenKind::Ident(name, _) => names.push(name.to_string()),
                TokenKind::Literal(lit) => names.push(lit.symbol.to_string()),
                _ => {}
            }
        }
    }
    Some(names)
}

fn check(cx: &EarlyContext<'_>, attrs: &[Attribute], data: &VariantData) {
    let sources = source_names(data);
    if sources.is_empty() {
        return;
    }
    for attr in attrs {
        if attr.span.from_expansion() {
            continue;
        }
        let Some(names) = interpolated(attr) else {
            continue;
        };
        if let Some(source) = names.iter().find(|name| sources.contains(name)) {
            span_lint_and_help(
                cx,
                THISERROR_SOURCE_IN_MESSAGE,
                attr.span,
                format!("`#[error]` message repeats its source `{source}`"),
                None,
                "name the step that failed; the source is printed when the chain is reported",
            );
        }
    }
}

impl EarlyLintPass for ThiserrorSourceInMessage {
    fn check_item(&mut self, cx: &EarlyContext<'_>, item: &Item) {
        match &item.kind {
            ItemKind::Enum(_, _, def) => {
                for variant in &def.variants {
                    check(cx, &variant.attrs, &variant.data);
                }
            }
            ItemKind::Struct(_, _, data) => check(cx, &item.attrs, data),
            _ => {}
        }
    }
}
