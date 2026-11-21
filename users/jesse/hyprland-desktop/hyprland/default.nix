{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (config.palette) alphaHex glass;
  supportedHyprland = "0.57.2";
  hyprland = osConfig.programs.hyprland.package;
  hyprctl = lib.getExe' hyprland "hyprctl";
  inherit (config.desktop) monitors;
  monitorOption = lib.types.submodule {
    options = {
      output = lib.mkOption { type = lib.types.str; };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "preferred";
      };
      position = lib.mkOption {
        type = lib.types.str;
        default = "auto";
      };
      scale = lib.mkOption {
        type = lib.types.number;
        default = 1;
      };
      transform = lib.mkOption {
        type = lib.types.ints.between 0 7;
        default = 0;
      };
    };
  };
  vars = {
    palette = config.palette.mocha;
    alpha.chrome = alphaHex glass.chrome;
    xrandr = lib.getExe pkgs.xrandr;
    outputs = lib.mapAttrs (_: monitor: monitor.output) monitors;
    monitors = [
      monitors.side
      monitors.main
    ];
    tohru =
      if config.programs.tohru.enable then lib.getExe' config.programs.tohru.package "tohru" else null;
    tohruPlugin = "${config.programs.tohru.hyprlandPlugin.package}/lib/libtohru-hyprland.so";
    screenshot = "env XDG_SCREENSHOTS_DIR=${config.home.sessionVariables.XDG_SCREENSHOTS_DIR} ${lib.getExe pkgs.grimblast} --notify --freeze copysave area";
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
  options.desktop.monitors = {
    main = lib.mkOption {
      type = monitorOption;
      description = "The monitor with the numbered workspaces.";
    };
    side = lib.mkOption {
      type = monitorOption;
      description = "The monitor with the side workspace.";
    };
  };

  config = {
    home.packages = [ pkgs.hyprland-quit ];

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
  };
}
