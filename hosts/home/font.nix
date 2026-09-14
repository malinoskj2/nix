# Font
{ config, pkgs, ... }:

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
