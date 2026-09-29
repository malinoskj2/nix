{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.wallpaper.launcher;
in
{
  options.wallpaper.launcher.enable = lib.mkEnableOption ''
    playing the video wallpapers from systemd units. Noctalia's mpvpaper plugin plays them otherwise
  '';

  config = {
    home.packages = [
      pkgs.wallpaper-randomize
      pkgs.wallpaper-select
    ];

    # Noctalia's plugin keeps the assignments and mpv's sockets in its own directory, where the
    # wallpaper scripts don't look.
    home.file = lib.mkIf (!cfg.enable) {
      ".local/state/wallpaper".source =
        config.lib.file.mkOutOfStoreSymlink "${config.xdg.stateHome}/noctalia/mpvpaper";
    };

    systemd.user.services = {
      wallpaper-autopause = {
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
    // lib.optionalAttrs cfg.enable {
      wallpaper-outputs = {
        Unit = {
          Description = "Run a video wallpaper on every connected monitor";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
          # Restarting it gives every monitor a new video, which a Home Manager switch shouldn't.
          X-SwitchMethod = "keep-old";
        };
        Service = {
          ExecStart = lib.getExe pkgs.wallpaper-outputs;
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      "wallpaper@" = {
        Unit = {
          Description = "Video wallpaper on %i";
          After = [ "wallpaper-outputs.service" ];
          BindsTo = [ "wallpaper-outputs.service" ];
          StartLimitIntervalSec = 60;
          StartLimitBurst = 10;
          X-SwitchMethod = "keep-old";
        };
        Service = {
          # %i, not %I: unescaping would turn DP-2 into DP/2.
          ExecStart = "${lib.getExe pkgs.wallpaper-play} %i";
          # mpvpaper exits successfully when it's killed, so only a stop from systemd ends it.
          Restart = "always";
          RestartSec = 2;
        };
      };
    };
  };
}
