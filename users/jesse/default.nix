{ config, pkgs, inputs, ... }:

{
  programs.home-manager.enable = true;

  home = {
    username = "jesse";
    homeDirectory = "/home/jesse";
    stateVersion = "25.11";
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
    starship
    cargo
    mediainfo
    redis
    bc
    pandoc
    dig
    whois
    jq
    firefox
    google-chrome
    nss
    nssTools
    postman
    nodejs
    twilio-cli
    nmap
    hyprpaper
    waybar
    grim
    slurp
    wl-clipboard
    libnotify
    wl-color-picker
    p7zip
    unrar
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
