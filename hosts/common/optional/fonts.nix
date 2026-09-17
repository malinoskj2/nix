# Fonts. sf-* and ny come from the apple-fonts overlay.
{ pkgs, ... }:
{
  fonts.packages = with pkgs; [
    lato
    fira-mono
    fira-code
    fira-code-symbols
    nerd-fonts.fira-code
    sf-pro
    sf-compact
    sf-mono
    ny
  ];
}
