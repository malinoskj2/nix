# Font
{ config, pkgs, ... }:

{
  fonts.packages = with pkgs; [
    lato
    fira-mono
    fira-code
    fira-code-symbols
    (nerdfonts.override { fonts = [ "FiraCode" "DroidSansMono" ]; })
    otf-apple
  ];
}
