{ pkgs, ... }:

let
  scripts = import ../../derivations/scripts.nix { inherit pkgs; };
in
{
  imports = [
    ./zsh.nix
    ./starship.nix
    ./alacritty.nix
    ./zed.nix
    ./claude.nix
    ./darwin-fastfetch.nix
  ];

  programs.home-manager.enable = true;

  home = {
    stateVersion = "26.05";

    packages =
      (with scripts; [
        aiUsage
        gitCommitu
        gitOpen
        pubip
      ])
      ++ (with pkgs; [
        git
        ripgrep
        fd
        eza
        tldr
        tokei
        file
        gnumake
        envsubst
        zip
        tree
        nixfmt
        nil
        jq
        nodejs
        neovim
        python3
        bc
        pandoc
        p7zip
        rustc
        cargo
        clippy
        rustfmt
        rust-analyzer
        bacon
        cargo-nextest
        cargo-audit
        pkg-config
        gnupg
        jetbrains.datagrip
        whois
        firefox-bin
        nssTools
        nmap
        unrar
        unstable.codex
        mpv
        htop-vim-navigation
        vim
        wget
        unzip
      ]);
  };
}
