# Points rust-analyzer at the Rust standard library sources from nixpkgs.
{ pkgs, ... }:
{
  home.sessionVariables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
}
