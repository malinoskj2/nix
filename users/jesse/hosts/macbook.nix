{ pkgs, ... }:
{
  imports = [
    ../global
    ../features/cli.nix
    ../features/dev.nix
    ../features/rust
  ];

  home.packages = with pkgs; [
    # Stable DataGrip, without the glass header; Linux uses features/datagrip.
    jetbrains.datagrip
    firefox-bin
    git
    htop-vim-navigation
    mpv
    unzip
    vim
    wget
  ];

  home.sessionVariables = {
    BROWSER = "open";
    DOWNLOAD = "$HOME/Downloads";
  };

  home.stateVersion = "26.05";
}
