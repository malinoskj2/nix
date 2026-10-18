{ osConfig, ... }:
{
  # NixOS owns the shell service and /etc/xdg configuration. Home Manager only
  # supplies the compositor library to this user's declarative Lua configuration.
  home.sessionVariables.J2BAR_BIN = "${osConfig.programs.j2bar.package}/bin/j2bar";
  home.packages = [ osConfig.programs.j2bar.hyprlandPlugin.package ];

  # A linked directory rather than linked files: j2bar only lists regular files in it.
  home.file.".wallpapers/video".source = ./wallpapers;
}
