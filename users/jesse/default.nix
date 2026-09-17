{
  pkgs,
  lib,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  scripts = import ../../derivations/scripts.nix { inherit pkgs; };

  scriptPackages =
    if isLinux then
      builtins.attrValues scripts
    else
      with scripts;
      [
        aiUsage
        gitCommitu
        gitOpen
        pubip
      ];

  commonPackages = with pkgs; [
    gnupg
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
    rustc
    cargo
    clippy
    rustfmt
    rust-analyzer
    pkg-config
    bacon
    cargo-nextest
    cargo-audit
    bc
    pandoc
    whois
    jq
    nssTools
    nodejs
    nmap
    p7zip
    unrar
    neovim
    unstable.codex
    python3
  ];

  linuxPackages = with pkgs; [
    gitleaks
    unstable.jetbrains.datagrip
    ffmpeg
    pavucontrol
    imagemagick
    killall
    clang
    mold
    lldb
    mediainfo
    dig
    google-chrome
    chromium
    wl-clipboard
    glib
    openzone-cursors
    ktx-tools
    ghidra
    vulkan-tools
  ];

  darwinPackages = with pkgs; [
    git
    jetbrains.datagrip
    firefox-bin
    mpv
    htop-vim-navigation
    vim
    wget
    unzip
  ];
in
{
  imports = [
    ./zsh.nix
    ./starship.nix
    ./fastfetch.nix
    ./zed.nix
    ./alacritty.nix
    ./claude.nix
  ]
  ++ lib.optionals isLinux [
    ./firefox.nix
    ./dolphin.nix
    ./git.nix
    ./mpv.nix
    ./cursor.nix
    ./htop.nix
  ];

  programs.home-manager.enable = true;

  home = {
    stateVersion = if isDarwin then "26.05" else "25.11";
    packages =
      scriptPackages
      ++ commonPackages
      ++ lib.optionals isLinux linuxPackages
      ++ lib.optionals isDarwin darwinPackages;
  }
  // lib.optionalAttrs isLinux {
    username = "jesse";
    homeDirectory = "/home/jesse";
    file.".config/JetBrains/DataGrip${lib.versions.majorMinor pkgs.unstable.jetbrains.datagrip.version}/extensions/com.intellij/startup/glass-header.groovy".source =
      ./datagrip-glass-header.groovy;
  };
}
// lib.optionalAttrs isLinux {
  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 50400;
    maxCacheTtl = 50400;
  };
}
