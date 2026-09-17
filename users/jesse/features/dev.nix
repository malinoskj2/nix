# Language tooling and build helpers every profile shares, macOS included.
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
