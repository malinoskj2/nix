{ config, inputs, ... }:
{
  imports = [ inputs.j2bar.homeModules.default ];

  home.sessionVariables.J2BAR_BIN = "${config.programs.j2bar.package}/bin/j2bar";

  programs.j2bar = {
    enable = true;
    hyprlandPlugin.enable = true;
    gameEngine.enable = false;
    # Off for now: the bar is started by hand from the dev checkout while the
    # cutover is in flight, and a session-started store build only duplicates it.
    systemd.enable = false;
    settings = {
      output = "DP-2";
      # Keep the current wallpaper and Steam services until their live cutover is validated.
      wallpaper.enabled = false;
      game.enabled = false;
    };
  };

  wallpaper.launcher.enable = true;
}
