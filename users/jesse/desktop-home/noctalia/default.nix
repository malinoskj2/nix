{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  inherit (pkgs.unstable) noctalia;
  palette = config.palette.mocha;

  # The snowflake's lambdas in workspace order: workspace 1 is the first colour.
  lambdaColors = map (name: palette.${name}) [
    "peach"
    "yellow"
    "teal"
    "lavender"
    "mauve"
    "pink"
  ];

  controlButton = {
    width = 52;
    height = 24;
    frameCount = 48;
    fps = 30;
  };

  controlButtonFrames =
    pkgs.runCommand "noctalia-control-button-frames"
      {
        nativeBuildInputs = [
          pkgs.imagemagick
          pkgs.python3
        ];
        colors = builtins.toJSON {
          inherit palette;
          lambdas = lambdaColors;
        };
      }
      ''
        python3 ${./plugins/control-button/render.py} ${./plugins/control-button/snowflake.svg} $out \
          --width ${toString controlButton.width} --height ${toString controlButton.height} \
          --frames ${toString controlButton.frameCount} --colors "$colors"
      '';

  # Prepends `local nix = { ... }` to a Luau script, the shape hyprland.lua receives.
  withNix =
    file: values:
    pkgs.writeText (baseNameOf file) (
      "local nix = ${lib.generators.toLua { } values}\n" + builtins.readFile file
    );

  plugins = {
    control-button = {
      "button.luau" = withNix ./plugins/control-button/button.luau {
        inherit (controlButton) width height fps;
        frame_count = controlButton.frameCount;
        noctalia = lib.getExe noctalia;
      };
      frames = controlButtonFrames;
    };
    hypr-workspaces = {
      "workspaces.luau" = withNix ./plugins/hypr-workspaces/workspaces.luau {
        colors = map (color: "#${color}") lambdaColors;
        hyprctl = lib.getExe' osConfig.programs.hyprland.package "hyprctl";
        sleep = lib.getExe' pkgs.coreutils "sleep";
        socat = lib.getExe pkgs.socat;
        stdbuf = lib.getExe' pkgs.coreutils "stdbuf";
      };
    };
  };
in
{
  home.packages = [
    noctalia
    # Noctalia's upstream mpvpaper plugin runs it from PATH.
    pkgs.mpvpaper
  ];

  # Validated the way Noctalia's own Home Manager module does.
  xdg.configFile."noctalia/config.toml".source =
    pkgs.runCommand "noctalia-config.toml" { nativeBuildInputs = [ noctalia ]; }
      ''
        noctalia config validate ${./config.toml}
        cp ${./config.toml} $out
      '';

  # Only what Noctalia loads is linked, so build inputs such as render.py stay out of $HOME,
  # and the build fails if `noctalia plugins lint` does.
  # recursive keeps each plugin directory a real directory: Noctalia hot-reloads a script
  # by watching its parent, which would otherwise be an immutable store path.
  xdg.dataFile = lib.mapAttrs' (
    name: files:
    lib.nameValuePair "noctalia/plugins/${name}" {
      source = pkgs.runCommand "noctalia-plugin-${name}" { nativeBuildInputs = [ noctalia ]; } ''
        mkdir $out
        ${lib.concatStrings (
          lib.mapAttrsToList (file: path: "ln -s ${path} $out/${file}\n") (
            { "plugin.toml" = ./plugins/${name}/plugin.toml; } // files
          )
        )}
        noctalia plugins lint $out
      '';
      recursive = true;
    }
  ) plugins;
}
