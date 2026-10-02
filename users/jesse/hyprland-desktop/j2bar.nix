{ config, ... }:
{
  # Both the development binary and ~/.config/j2bar/config.toml are managed outside Nix.
  home.sessionVariables.J2BAR_BIN = "${config.home.homeDirectory}/projects/j2bar/target/release/j2bar";

  wallpaper.launcher.enable = true;
}
