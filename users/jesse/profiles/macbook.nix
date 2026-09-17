{ pkgs, ... }:
{
  imports = [
    ../global

    ../features/cli.nix
    ../features/dev.nix
    ../features/rust
  ];

  # Check the name with `id -un` before the first switch.
  home = {
    username = "jmalinosky";
    homeDirectory = "/Users/jmalinosky";
  };

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    # This profile stays conservative, so programs with shared modules install as plain packages.
    fira-code
    fira-mono
    firefox-bin
    git
    btop
    htop-vim-navigation
    jetbrains.datagrip
    lato
    mpv
    nerd-fonts.fira-code

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
