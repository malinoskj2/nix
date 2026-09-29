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
    sccache
  ];

  home.sessionVariables = {
    LIBGIT2_SYS_USE_PKG_CONFIG = "1";
    RUSTC_WRAPPER = "sccache";
    SCCACHE_CACHE_SIZE = "50G";
  };
}
