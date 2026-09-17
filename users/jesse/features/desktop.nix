# Graphical Linux desktop: browser, file manager, media and cursor.
{ pkgs, ... }:
{
  imports = [
    ../cursor.nix
    ../dolphin
    ../firefox.nix
    ../mpv.nix
  ];

  home.packages = with pkgs; [
    ffmpeg
    pavucontrol
    imagemagick
    mediainfo
    google-chrome
    chromium
    wl-clipboard
    glib
    ktx-tools
    vulkan-tools
  ];

  home.sessionVariables = {
    BROWSER = "firefox";
    DOWNLOAD = "/media/scratch/download";
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 50400;
    maxCacheTtl = 50400;
  };
}
