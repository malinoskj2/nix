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

  home.sessionVariables.LIBGIT2_SYS_USE_PKG_CONFIG = "1";
}
