{
  jesseScripts,
  pkgs,
  ...
}:

let
  noctalia = pkgs.unstable.noctalia;
  hyprlandConfig = pkgs.replaceVars ./hyprland/hyprland.lua {
    hyprbars = "${pkgs.hyprlandPlugins.hyprbars}/lib/libhyprbars.so";
    hyprfocus = "${pkgs.hyprlandPlugins.hyprfocus}/lib/libhyprfocus.so";
    wallpaperRandomize = jesseScripts.wallpaperRandomize;
    noctalia = "${noctalia}/bin/noctalia";
  };
in
{
  assertions = [
    {
      assertion = pkgs.hyprland.version == "0.56.2";
      message = "The home desktop Lua configuration and plugins are pinned for Hyprland 0.56.2.";
    }
  ];

  home.packages = [
    noctalia
    pkgs.mpvpaper
    pkgs.socat
  ];

  xdg.configFile = {
    "hypr/hyprland.lua".source = hyprlandConfig;
    "hypr/actions.lua".source = ./hyprland/actions.lua;
    "noctalia/config.toml".source = ./noctalia/config.toml;
  };

  xdg.dataFile = {
    "noctalia/plugins/control-button" = {
      source = ./noctalia/plugins/control-button;
      recursive = true;
    };
    "noctalia/plugins/hypr-workspaces" = {
      source = ./noctalia/plugins/hypr-workspaces;
      recursive = true;
    };
  };

  systemd.user.services.wallpaper-autopause = {
    Unit = {
      Description = "Pause Noctalia video wallpapers behind windows and the lock screen";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${jesseScripts.wallpaperAutopause}/bin/wallpaper-autopause";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
