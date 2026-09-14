{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  noctalia = unstable.noctalia;

  wallpaperRandomize = pkgs.writeShellApplication {
    name = "wallpaper-randomize";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      jq
    ];
    text = builtins.readFile ./scripts/wallpaper-randomize.sh;
  };

  wallpaperAutopause = pkgs.writeShellApplication {
    name = "wallpaper-autopause";
    runtimeInputs = [
      noctalia
      pkgs.coreutils
      pkgs.dbus
      pkgs.glib
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.systemd
    ];
    text = builtins.readFile ./scripts/wallpaper-autopause.sh;
  };

  hyprlandConfig = pkgs.replaceVars ./hyprland/hyprland.lua {
    hyprbars = "${pkgs.hyprlandPlugins.hyprbars}/lib/libhyprbars.so";
    hyprfocus = "${pkgs.hyprfocus}/lib/libhyprfocus.so";
    inherit wallpaperRandomize;
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
    wallpaperRandomize
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

  # These were manually-created links, so Home Manager did not know to remove
  # them. Unlink only the known legacy paths; their source files remain intact
  # for rollback. The Lua entry point and Noctalia files are then linked from
  # the Nix store by the declarations above.
  home.activation.removeLegacyDesktopLinks = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    for relativePath in \
      hypr/hyprland.conf \
      hypr/hyprpaper.conf \
      hypr/hyprlock.conf \
      noctalia/config.toml \
      waybar/config \
      waybar/style.css \
      ../.local/share/noctalia/plugins/control-button \
      ../.local/share/noctalia/plugins/hypr-workspaces
    do
      legacyPath="${config.home.homeDirectory}/.config/$relativePath"
      if [ -L "$legacyPath" ]; then
        $DRY_RUN_CMD rm -- "$legacyPath"
      fi
    done
  '';

  systemd.user.services.wallpaper-autopause = {
    Unit = {
      Description = "Pause Noctalia video wallpapers behind windows and the lock screen";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${wallpaperAutopause}/bin/wallpaper-autopause";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
