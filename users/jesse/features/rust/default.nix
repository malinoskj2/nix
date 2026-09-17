# Rust toolchain and cargo helpers.
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    bacon
    cargo
    cargo-audit
    cargo-nextest
    clippy
    rust-analyzer
    rustc
    rustfmt
  ];
}
