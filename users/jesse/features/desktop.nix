{ pkgs, ... }:
{
  imports = [
    ../dolphin
    ../firefox.nix
    ../mpv.nix
    ../pointer-cursor.nix
  ];

  home.packages = with pkgs; [
    blender
    chromium
    ffmpeg
    glib
    google-chrome
    imagemagick
    ktx-tools
    mediainfo
    pwvucontrol
    vulkan-tools
    wl-clipboard
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
