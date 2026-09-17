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
        # The active border stays outside the glass levels because it marks focus, not a surface.
        active_border = alphaHex 99;
        chrome = alphaHex glass.chrome;
      };
      control_button_id = (lib.importTOML ../noctalia/plugins/control-button/plugin.toml).id;
      # Hyprland swaps plugins its config loads through `hl.plugin.load` when a switch changes their
      # store paths; the module's `plugins` option runs `hyprctl plugin load` only once at startup.
      hyprbars = "${pkgs.hyprlandPlugins.hyprbars}/lib/libhyprbars.so";
      hyprfocus = "${pkgs.hyprlandPlugins.hyprfocus}/lib/libhyprfocus.so";
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
    # The Home Manager module writes this only when it owns the Hyprland package.
    "hypr/.luarc.json".text = builtins.toJSON {
      diagnostics.globals = [ "hl" ];
      workspace.library = [ "${hyprland}/share/hypr/stubs" ];
    };
    "hypr/actions.lua".source = ./actions.lua;
  };
}
