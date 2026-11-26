#![feature(rustc_private)]
#![feature(default_field_values)]
#![warn(unused_extern_crates)]

extern crate rustc_ast;
extern crate rustc_attr_ir;
extern crate rustc_hir;
extern crate rustc_lint;
extern crate rustc_middle;
extern crate rustc_session;
extern crate rustc_span;

mod blocking_call_in_async;
mod bool_literal_argument;
mod catch_all_module;
mod detached_spawn;
mod error_string_matching;
mod local_enum_wildcard_arm;
mod manual_error_impl;
mod missing_item_separator;
mod paths;
mod stringly_error;
mod thiserror_source_in_message;

dylint_linting::dylint_library!();

#[expect(clippy::no_mangle_with_rust_abi, reason = "Dylint loads this symbol by name")]
#[unsafe(no_mangle)]
pub fn register_lints(sess: &rustc_session::Session, lint_store: &mut rustc_lint::LintStore) {
    dylint_linting::init_config(sess);
    lint_store.register_lints(&[
        blocking_call_in_async::BLOCKING_CALL_IN_ASYNC,
        bool_literal_argument::BOOL_LITERAL_ARGUMENT,
        catch_all_module::CATCH_ALL_MODULE,
        detached_spawn::DETACHED_SPAWN,
        error_string_matching::ERROR_STRING_MATCHING,
        local_enum_wildcard_arm::LOCAL_ENUM_WILDCARD_ARM,
        manual_error_impl::MANUAL_ERROR_IMPL,
        missing_item_separator::MISSING_ITEM_SEPARATOR,
        stringly_error::STRINGLY_ERROR,
        thiserror_source_in_message::THISERROR_SOURCE_IN_MESSAGE,
    ]);
    lint_store.register_early_lint_pass(Box::new(|| Box::new(catch_all_module::CatchAllModule)));
    lint_store.register_early_lint_pass(Box::new(|| Box::new(missing_item_separator::MissingItemSeparator)));
    lint_store.register_early_lint_pass(Box::new(|| {
        Box::new(thiserror_source_in_message::ThiserrorSourceInMessage)
    }));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(blocking_call_in_async::BlockingCallInAsync)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(bool_literal_argument::BoolLiteralArgument)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(detached_spawn::DetachedSpawn)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(error_string_matching::ErrorStringMatching)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(local_enum_wildcard_arm::LocalEnumWildcardArm)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(manual_error_impl::ManualErrorImpl)));
    lint_store.register_late_lint_pass(Box::new(|_| Box::new(stringly_error::StringlyError)));
}

#[test]
fn ui() {
    dylint_testing::ui::Test::src_base(env!("CARGO_PKG_NAME"), "ui")
        .rustc_flags(["--edition=2024"])
        .run();
}

#[test]
fn ui_examples() {
    dylint_testing::ui_test_examples(env!("CARGO_PKG_NAME"));
}
