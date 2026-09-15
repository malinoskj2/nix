{
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./firefox.nix
    ./dolphin.nix
    ./git.nix
    ./zsh.nix
    ./mpv.nix
    ./starship.nix
    ./cursor.nix
    ../../scripts
    ./fastfetch.nix
    ./htop.nix
    ./zed.nix
    ./alacritty.nix
    ./claude.nix
  ];

  programs.home-manager.enable = true;

  home = {
    username = "jesse";
    homeDirectory = "/home/jesse";
    stateVersion = "25.11";
  };

  home.file.".config/JetBrains/DataGrip${lib.versions.majorMinor pkgs.unstable.jetbrains.datagrip.version}/extensions/com.intellij/startup/glass-header.groovy".source =
    ./datagrip-glass-header.groovy;

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 50400;
    maxCacheTtl = 50400;
  };

  home.packages = with pkgs; [
    gnupg
    ripgrep
    fd
    eza
    tldr
    tokei
    gitleaks
    unstable.jetbrains.datagrip
    ffmpeg
    pavucontrol
    imagemagick
    file
    gnumake
    envsubst
    killall
    zip
    tree
    nixfmt
    nil
    rustc
    cargo
    clippy
    rustfmt
    rust-analyzer
    clang
    mold
    pkg-config
    lldb
    bacon
    cargo-nextest
    cargo-audit
    mediainfo
    bc
    pandoc
    dig
    whois
    jq
    google-chrome
    chromium
    nssTools
    nodejs
    nmap
    wl-clipboard
    p7zip
    unrar
    glib
    openzone-cursors
    neovim
    unstable.codex
    ktx-tools
    python3
    ghidra
    vulkan-tools
  ];
}
