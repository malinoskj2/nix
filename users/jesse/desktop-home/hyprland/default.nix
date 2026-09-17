{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  inherit (config.palette) alphaHex glass;
  hyprland = osConfig.programs.hyprland.package;
in
{
  assertions = [
    {
      assertion = hyprland.version == "0.56.2";
      message = "The home desktop Lua configuration and plugins are pinned for Hyprland 0.56.2.";
    }
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "lua";
    # Installed by the NixOS module.
    package = null;
    portalPackage = null;
    # Rendered as `local nix = { ... }` ahead of hyprland.lua.
    settings.nix._var = {
      alpha = {
        chrome = alphaHex glass.chrome;
        # Near-opaque, deliberately not a glass level.
        active_border = alphaHex 99;
      };
      control_button = (lib.importTOML ../noctalia/plugins/control-button/plugin.toml).id;
      # Loaded with hl.plugin.load rather than the module's `plugins` option, which
      # runs `hyprctl plugin load` once at startup: config-declared plugins are
      # swapped by Hyprland itself when a switch changes their store paths.
      hyprbars = "${pkgs.hyprlandPlugins.hyprbars}/lib/libhyprbars.so";
      hyprfocus = "${pkgs.hyprlandPlugins.hyprfocus}/lib/libhyprfocus.so";
      hyprctl = lib.getExe' hyprland "hyprctl";
      monitors = {
        main = "DP-2";
        side = "DP-1";
      };
      noctalia = lib.getExe pkgs.unstable.noctalia;
      palette = config.palette.mocha;
      wallpaper_randomize = lib.getExe pkgs.wallpaper-randomize;
      workspaces = {
        first = 1;
        last = 5;
      };
    };
    extraConfig = builtins.readFile ./hyprland.lua;
  };

  xdg.configFile = {
    # The module only writes this when it owns the Hyprland package.
    "hypr/.luarc.json".text = builtins.toJSON {
      workspace.library = [ "${hyprland}/share/hypr/stubs" ];
      diagnostics.globals = [ "hl" ];
    };
    "hypr/actions.lua".source = ./actions.lua;
  };
}
