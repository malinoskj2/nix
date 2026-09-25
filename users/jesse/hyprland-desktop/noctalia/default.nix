{
  config,
  inputs,
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
    calendar = {
      "calendar.luau" = withNix ./plugins/calendar/calendar.luau { inherit palette; };
    };
    sound = {
      "sound.luau" = withNix ./plugins/sound/sound.luau {
        inherit palette;
        settings = lib.getExe pkgs.pwvucontrol;
        state = lib.getExe (
          pkgs.writeShellApplication {
            name = "noctalia-sound-state";
            runtimeInputs = [
              pkgs.jq
              pkgs.pipewire
              pkgs.wireplumber
            ];
            text = builtins.readFile ./plugins/sound/state.sh;
          }
        );
        wpctl = lib.getExe' pkgs.wireplumber "wpctl";
      };
    };
    network = {
      "network.luau" = withNix ./plugins/network/network.luau {
        inherit palette;
        ip = lib.getExe' pkgs.iproute2 "ip";
        noctalia = lib.getExe noctalia;
      };
    };
    apple-menu = {
      "menu.luau" = withNix ./plugins/apple-menu/menu.luau {
        inherit hyprctl palette;
        noctalia = lib.getExe noctalia;
        user = config.home.username;
      };
    };
    about = {
      "about.luau" = withNix ./plugins/about/about.luau {
        inherit palette;
        title = "NixOS Desktop";
        hostname = osConfig.networking.hostName;
        nixos = "${osConfig.system.nixos.codeName} ${osConfig.system.nixos.release}";
        revision =
          let
            revision = osConfig.system.configurationRevision;
          in
          if revision == null then
            "dirty"
          else
            lib.substring 0 7 revision + lib.optionalString (lib.hasSuffix "-dirty" revision) "-dirty";
        built =
          let
            date = inputs.self.lastModifiedDate;
            month = lib.elemAt [
              "January"
              "February"
              "March"
              "April"
              "May"
              "June"
              "July"
              "August"
              "September"
              "October"
              "November"
              "December"
            ] (lib.toInt (lib.removePrefix "0" (lib.substring 4 2 date)) - 1);
          in
          "Built ${lib.removePrefix "0" (lib.substring 6 2 date)} ${month} ${lib.substring 0 4 date}";
        repository = {
          name = "github.com/malinoskj2/nix";
          url = "https://github.com/malinoskj2/nix";
        };
        monitor = [
          (lib.getExe config.programs.alacritty.package)
          "--command"
          (lib.getExe config.programs.btop.package)
        ];
        open = lib.getExe' pkgs.xdg-utils "xdg-open";
        state = lib.getExe (
          pkgs.writeShellApplication {
            name = "noctalia-about-state";
            runtimeInputs = [
              pkgs.gawk
              pkgs.jq
              pkgs.pciutils
              pkgs.util-linux
            ];
            text = builtins.readFile ./plugins/about/state.sh;
          }
        );
      };
    };
    control-button = {
      "button.luau" = withNix ./plugins/control-button/button.luau (
        controlButton
        // {
          menu = "jesse/apple-menu:menu";
          noctalia = lib.getExe noctalia;
        }
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
