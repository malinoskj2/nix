{ inputs, pkgs, ... }:
{
  imports = [ inputs.j2bar.homeModules.default ];

  programs.j2bar = {
    enable = true;
    package = pkgs.j2bar;
    settings = {
      output = "DP-2";
    };
  };

  wallpaper.launcher.enable = true;
}
