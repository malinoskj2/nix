{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (pkgs.unstable) noctalia;

  controlButton = {
    fps = 30;
    frame_count = 48;
    height = 24;
    width = 52;
  };

  withNix =
    file: values:
    pkgs.writeText (baseNameOf file) (
      "local nix = ${lib.generators.toLua { } values}\n" + builtins.readFile file
    );

  # Links only the files Noctalia loads, so build inputs such as render.py stay out of $HOME, and
  # fails the build if `noctalia plugins lint` does.
  mkPluginDir =
    name: files:
    let
      links = files // {
        "plugin.toml" = ./plugins/${name}/plugin.toml;
      };
    in
    pkgs.runCommand "noctalia-plugin-${name}" { nativeBuildInputs = [ noctalia ]; } ''
      mkdir $out
      ${lib.concatLines (lib.mapAttrsToList (file: path: "ln -s ${path} $out/${file}") links)}
      noctalia plugins lint $out
    '';

  hyprctl = lib.getExe' osConfig.programs.hyprland.package "hyprctl";
  palette = config.palette.mocha;

  # The snowflake's lambdas in workspace order: workspace 1 takes the first color.
  lambdaColors = map (name: palette.${name}) [
    "peach"
    "yellow"
    "teal"
    "lavender"
    "mauve"
    "pink"
  ];

  controlButtonFrames =
    pkgs.runCommand "noctalia-control-button-frames"
      {
        nativeBuildInputs = [
          pkgs.imagemagick
          pkgs.python3
        ];
      }
      ''
        python3 ${./plugins/control-button/render.py} \
          --logo ${./plugins/control-button/snowflake.svg} \
          --out-dir $out \
          --width ${toString controlButton.width} \
          --height ${toString controlButton.height} \
          --frame-count ${toString controlButton.frame_count} \
          --palette ${lib.escapeShellArg (builtins.toJSON palette)} \
          --lambdas ${lib.escapeShellArg (builtins.toJSON lambdaColors)}
      '';

  plugins = {
    control-button = {
      "button.luau" = withNix ./plugins/control-button/button.luau (
        controlButton // { noctalia = lib.getExe noctalia; }
      );

      frames = controlButtonFrames;
    };

    hypr-workspaces = {
      "workspaces.luau" = withNix ./plugins/hypr-workspaces/workspaces.luau {
        inherit hyprctl;
        colors = map (color: "#${color}") lambdaColors;
        sleep = lib.getExe' pkgs.coreutils "sleep";
        socat = lib.getExe pkgs.socat;
        stdbuf = lib.getExe' pkgs.coreutils "stdbuf";
      };
    };
  };
in
{
  home.packages = [
    # Noctalia's upstream mpvpaper plugin runs it from PATH.
    pkgs.mpvpaper
    noctalia
  ];

  # Noctalia's own Home Manager module validates the config the same way, so a bad setting fails
  # the build instead of the shell.
  xdg.configFile."noctalia/config.toml".source =
    pkgs.runCommand "noctalia-config.toml" { nativeBuildInputs = [ noctalia ]; }
      ''
        noctalia config validate ${./config.toml}
        cp ${./config.toml} $out
      '';

  xdg.dataFile = lib.mapAttrs' (
    name: files:
    lib.nameValuePair "noctalia/plugins/${name}" {
      source = mkPluginDir name files;
      # Noctalia hot-reloads a script by watching its parent directory, which must therefore be
      # a real directory rather than an immutable store path.
      recursive = true;
    }
  ) plugins;
}
