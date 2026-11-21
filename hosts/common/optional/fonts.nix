{ pkgs, ... }:
{
  # The order reaches fontconfig's font directory list, so this list stays unsorted.
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
  fonts.fontconfig.defaultFonts = {
    sansSerif = [ "SF Pro Text" ];
    serif = [ "New York" ];
    monospace = [ "SF Mono" ];
  };
}
