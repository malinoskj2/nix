{ inputs, pkgs, ... }:
{
  imports = [ inputs.j2bar.homeModules.default ];

  programs.j2bar = {
    enable = true;
    package = pkgs.j2bar;
    settings = {
      output = "DP-2";
      control_button = {
        x = 6;
        y = 4;
      };
    };
  };

  wallpaper.launcher.enable = true;
}
