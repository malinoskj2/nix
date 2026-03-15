# Font
{ config, pkgs, ... }:

{
  fonts.packages = with pkgs; [
    lato
    fira-mono
    fira-code
    fira-code-symbols
    nerd-fonts.fira-code
    nerd-fonts.droid-sans-mono
    # otf-apple (fix later)
  ];
}
