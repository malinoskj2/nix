{ config, pkgs, inputs, ... }:

{
  programs.home-manager.enable = true;

  home = {
    username = "jesse";
    homeDirectory = "/home/jesse";
    stateVersion = "24.11";
  };

  home.file = {
    zsh = {
      source = "/home/jesse/env/zsh/zshrc";
      target = ".zshrc";
    };
    git = {
      source = "/home/jesse/env/config/git/gitconfig";
      target = ".gitconfig";
    };
    mpv = {
      source = "/home/jesse/env/config/mpv/mpv.conf";
      target = ".config/mpv/mpv.conf";
    };
    starship = {
      source = "/home/jesse/env/config/starship/starship.toml";
      target = ".config/starship.toml";
    };
    gtk2 = {
      source = "/home/jesse/env/config/gtk/gtkrc-2.0";
      target = ".gtkrc-2.0";
    };
    gtk3 = {
      source = "/home/jesse/env/config/gtk/settings.ini";
      target = ".config/gtk-3.0/settings.ini";
    };
    icon-theme = {
      source = "/home/jesse/env/config/gtk/index.theme";
      target = ".icons/default/index.theme";
    };
    xsettingsd = {
      source = "/home/jesse/env/config/gtk/xsettingsd.conf";
      target = ".config/xsettingsd/xsettingsd.conf";
    };
  };

  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    defaultCacheTtl = 50400;
    maxCacheTtl = 50400;
    maxCacheTtlSsh = 50400;
  };

  home.packages = with pkgs; [
    gnupg
    bat
    neofetch
    htop-vim
    ripgrep
    fd
    eza
    tldr
    tokei
    alacritty
    mpv
    feh
    jetbrains.datagrip
    stylua
    sumneko-lua-language-server
    xclip
    ffmpeg
    pavucontrol
    imagemagick
    file
    shellcheck
    bitwarden-cli
    gnumake
    envsubst
    redis
    mysql80
    killall
    zip
    tree
    nixfmt
    jetbrains.phpstorm
    xorg.xev
    xorg.xkbcomp
    xorg.xmodmap
    terraform
    terraformer
    pre-commit
    awscli2
    xdotool
    starship
    cargo
    mediainfo
    redis
    bc
    pandoc
    dig
    whois
    sox
    iperf
    jq
    mesa
    glmark2
    glxinfo
    i7z
    lm_sensors
    firefox
    google-chrome
    nss
    nssTools
    php
    php82Packages.composer
    php82Packages.php-codesniffer
    postman
    nodejs
    twilio-cli
    nmap
    speedtest-cli
    nodePackages.intelephense
    luajit
    hyprpaper
    waybar
    grim
    slurp
    wl-clipboard
    obs-studio
    libnotify
    wl-color-picker
    eww
    python3
    python312Packages.pip
    hyprlock
    yaml-language-server
    docker-compose-language-service
    dockerfile-language-server-nodejs
    vscode-langservers-extracted
    p7zip
    unrar
    php82Packages.phpmd
    neovide
    smartmontools
    bruno
    xorg.xlsclients
    nwg-look
    glib
    graphite-cursors
    quintom-cursor-theme
    whitesur-cursors
    openzone-cursors
    capitaine-cursors
    neovim
    zed-editor
  ];
}
