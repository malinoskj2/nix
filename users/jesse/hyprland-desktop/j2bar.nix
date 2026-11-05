{ lib, osConfig, ... }:
{
  home.sessionVariables.J2BAR_BIN = lib.getExe osConfig.programs.j2bar.package;
  home.packages = [ osConfig.programs.j2bar.hyprlandPlugin.package ];

  # A linked directory rather than linked files: j2bar only lists regular files in it.
  home.file.".wallpapers/video".source = ./wallpapers;
}
