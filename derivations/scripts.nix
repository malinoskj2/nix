{ pkgs }:

{
  aiUsage = pkgs.callPackage ./ai-usage { };
  ataDevs = pkgs.callPackage ./ata-devs { };
  battery = pkgs.callPackage ./battery { };
  findService = pkgs.callPackage ./find-service { };
  gitCommitu = pkgs.callPackage ./git-commitu { };
  gitOpen = pkgs.callPackage ./git-open { };
  pubip = pkgs.callPackage ./pubip { };
  wallpaperAutopause = pkgs.callPackage ./wallpaper-autopause {
    noctalia = pkgs.unstable.noctalia;
  };
  wallpaperRandomize = pkgs.callPackage ./wallpaper-randomize { };
  wallpaperSelect = pkgs.callPackage ./wallpaper-select {
    noctalia = pkgs.unstable.noctalia;
  };
  wifiConnect = pkgs.callPackage ./wifi-connect { };
}
