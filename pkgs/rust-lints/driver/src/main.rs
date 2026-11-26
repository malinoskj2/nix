#![feature(rustc_private)]

fn main() -> anyhow::Result<()> {
    env_logger::init();
    let args: Vec<_> = std::env::args_os().collect();
    dylint_driver::dylint_driver(&args)
}
