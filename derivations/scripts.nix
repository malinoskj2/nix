{ pkgs }:

{
  aiUsage = pkgs.callPackage ./ai-usage { };
  ataDevs = pkgs.callPackage ./ata_devs { };
  battery = pkgs.callPackage ./battery { };
  findService = pkgs.callPackage ./find_service { };
  gitCommitu = pkgs.callPackage ./git-commitu { };
  gitOpen = pkgs.callPackage ./git-open { };
  pubip = pkgs.callPackage ./pubip { };
  wallpaperAutopause = pkgs.callPackage ./wallpaper-autopause {
    noctalia = pkgs.unstable.noctalia;
  };
  wallpaperRandomize = pkgs.callPackage ./wallpaper-randomize { };
  wallpaperSelect = pkgs.callPackage ./wallpaper_select {
    noctalia = pkgs.unstable.noctalia;
  };
  wifiConnect = pkgs.callPackage ./wifi_connect { };
}
