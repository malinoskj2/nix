{ pkgs, ... }:
{
  home.sessionVariables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
}
