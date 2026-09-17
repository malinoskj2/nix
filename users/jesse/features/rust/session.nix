# Rust session environment for x86_64 Linux: std sources for rust-analyzer and
# linking with mold (from features/native.nix).
{ pkgs, ... }:
{
  home.sessionVariables = {
    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
  };
}
