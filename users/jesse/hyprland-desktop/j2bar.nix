{ inputs, pkgs, ... }:
{
  imports = [ inputs.j2bar.homeModules.default ];

  # Without an index.theme in the profile's hicolor, an icon lookup only searches a few sizes
  # there, and j2bar's launcher and window title miss apps like Zed and Orca that ship a single
  # 512x512 icon.
  home.packages = [ pkgs.hicolor-icon-theme ];

  programs.j2bar = {
    enable = true;
    package = pkgs.j2bar;
    systemd.enable = true;
    settings = {
      output = "DP-2";
      control_button = {
        x = 50;
        y = 16;
      };
    };
  };
}
