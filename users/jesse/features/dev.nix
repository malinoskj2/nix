{ pkgs, ... }:
{
  home.packages = with pkgs; [
    gnumake
    nil
    nixfmt
    nodejs
    pkg-config
    python3

    unstable.codex
  ];
}
