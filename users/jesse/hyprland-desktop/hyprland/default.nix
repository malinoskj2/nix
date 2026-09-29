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
  # Prepended to hyprland.lua and look.lua as `nix`.
  vars = {
    inherit hyprctl palette;
    alpha = {
      chrome = alphaHex glass.chrome;
    };
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
    j2bar = lib.getExe config.programs.j2bar.package;
    workspaces = {
      first = 1;
      last = 5;
    };
  };
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
    settings.nix._var = vars;
    extraConfig = builtins.readFile ./hyprland.lua;
  };

  xdg.configFile = {
    "hypr/hyprland.lua".onChange = reload;
    # The Home Manager module writes this only when it owns the Hyprland package.
    "hypr/.luarc.json".text = builtins.toJSON {
      diagnostics.globals = [ "hl" ];
      workspace.library = [ "${hyprland}/share/hypr/stubs" ];
    };
    # agent-sandbox's nested Hyprland loads this without hyprland.lua, so it carries its own `nix`.
    "hypr/look.lua" = {
      text = "local nix = ${lib.generators.toLua { } vars}\n\n${builtins.readFile ./look.lua}";
      onChange = reload;
    };
    "hypr/actions.lua" = {
      source = ./actions.lua;
      onChange = reload;
    };
  };
}
