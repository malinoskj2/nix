{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.packages = [
    pkgs.wallpaper-randomize
    pkgs.wallpaper-select
  ];

  # Noctalia's plugin keeps the assignments and mpv's sockets in its own directory, where the
  # wallpaper scripts don't look.
  home.file.".local/state/wallpaper".source =
    config.lib.file.mkOutOfStoreSymlink "${config.xdg.stateHome}/noctalia/mpvpaper";

  systemd.user.services.wallpaper-autopause = {
    Unit = {
      Description = "Pause video wallpapers behind windows and the lock screen";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = lib.getExe pkgs.wallpaper-autopause;
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
