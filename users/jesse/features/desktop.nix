# Graphical and media apps the Linux workstations share under any desktop,
# with their session defaults and the GPG agent that signs commits.
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
    pavucontrol
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
