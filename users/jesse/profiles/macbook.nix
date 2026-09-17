{ pkgs, ... }:
{
  imports = [
    ../global

    ../features/cli.nix
    ../features/dev.nix
    ../features/rust
  ];

  home.packages = with pkgs; [
    # This profile stays conservative, so programs with shared modules install as plain packages.
    firefox-bin
    git
    htop-vim-navigation
    jetbrains.datagrip
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
