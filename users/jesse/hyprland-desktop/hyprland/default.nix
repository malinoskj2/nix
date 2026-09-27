{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (config.palette) alphaHex glass;
  supportedHyprland = "0.56.2";
  hyprland = osConfig.programs.hyprland.package;
  hyprctl = lib.getExe' hyprland "hyprctl";
  palette = config.palette.mocha;
  # The Home Manager module reloads Hyprland after a switch only when it owns the Hyprland package.
  reload = ''
    export XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    if [[ -d $XDG_RUNTIME_DIR/hypr ]]; then
      for i in $(${hyprctl} instances -j | ${lib.getExe pkgs.jq} -r '.[].instance'); do
        ${hyprctl} -i "$i" reload config-only
      done
    fi
  '';
in
{
  assertions = [
    {
      assertion = hyprland.version == supportedHyprland;
      message = "The Hyprland desktop's Lua configuration and plugins are pinned for Hyprland ${supportedHyprland}.";
    }
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    # The NixOS module installs both.
    package = null;
    portalPackage = null;
    configType = "lua";
    settings.nix._var = {
      inherit hyprctl palette;
      alpha = {
        chrome = alphaHex glass.chrome;
      };
      control_button_id = (lib.importTOML ../noctalia/plugins/control-button/plugin.toml).id;
      # Hyprland swaps plugins its config loads through `hl.plugin.load` when a switch changes their
      # store paths; the module's `plugins` option runs `hyprctl plugin load` only once at startup.
      hyprbars = "${pkgs.hyprlandPlugins.hyprbars}/lib/libhyprbars.so";
      hyprfocus = "${pkgs.hyprlandPlugins.hyprfocus}/lib/libhyprfocus.so";
      hyprglass = "${pkgs.hyprglass}/lib/libhyprglass.so";
      hyprsheet = "${pkgs.hyprsheet}/lib/libhyprsheet.so";
      monitors = {
        main = "DP-2";
        side = "DP-1";
      };
      noctalia = lib.getExe pkgs.unstable.noctalia;
      wallpaper_randomize = lib.getExe pkgs.wallpaper-randomize;
      workspaces = {
        first = 1;
        last = 5;
      };
    };
    extraConfig = builtins.readFile ./hyprland.lua;
  };

  xdg.configFile = {
    "hypr/hyprland.lua".onChange = reload;
    # The Home Manager module writes this only when it owns the Hyprland package.
    "hypr/.luarc.json".text = builtins.toJSON {
      diagnostics.globals = [ "hl" ];
      workspace.library = [ "${hyprland}/share/hypr/stubs" ];
    };
    "hypr/actions.lua" = {
      source = ./actions.lua;
      onChange = reload;
    };
  };
}
