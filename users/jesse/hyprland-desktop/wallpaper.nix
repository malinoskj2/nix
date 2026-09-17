{ lib, pkgs, ... }:
{
  home.packages = [
    pkgs.wallpaper-randomize
    pkgs.wallpaper-select
  ];

  systemd.user.services.wallpaper-autopause = {
    Unit = {
      Description = "Pause Noctalia video wallpapers behind windows and the lock screen";
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
