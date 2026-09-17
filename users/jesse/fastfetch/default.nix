{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  inherit (config.palette) mocha rgb;

  module = type: color: {
    inherit type;
    keyColor = "#${color}";
  };
  onLinux = lib.optional isLinux;

  # The colors module only shows the 16 ANSI colors, which have no peach. Two identical rows make
  # each swatch a block rather than a thin stripe.
  swatchRow = {
    type = "custom";
    format =
      lib.concatMapStrings (color: "{#48;2;${lib.concatMapStringsSep ";" toString (rgb color)}}   ") (
        with mocha;
        [
          red
          peach
          yellow
          green
          teal
          blue
          lavender
          mauve
          pink
        ]
      )
      + "{#}";
  };
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      display = {
        separator = "  ";
        color = {
          title = "#${mocha.mauve}";
          output = "#${mocha.text}";
          separator = "#${mocha.overlay0}";
        };
      };

      # macOS keeps the shorter module list (and pink terminal key) of the separate macOS config this
      # file absorbed; that config never listed kernel, packages, wm to cursor, terminalfont or swap.
      modules = lib.flatten [
        "title"
        "separator"
        (module "os" mocha.mauve)
        (module "host" mocha.pink)
        (onLinux (module "kernel" mocha.peach))
        (module "uptime" mocha.yellow)
        (onLinux (module "packages" mocha.teal))
        (module "shell" mocha.lavender)
        (module "display" mocha.mauve)
        (onLinux [
          (module "wm" mocha.pink)
          (module "theme" mocha.peach)
          (module "icons" mocha.yellow)
          (module "font" mocha.teal)
          (module "cursor" mocha.lavender)
        ])
        (module "terminal" (if isLinux then mocha.mauve else mocha.pink))
        (onLinux (module "terminalfont" mocha.pink))
        (module "cpu" mocha.peach)
        (module "gpu" mocha.yellow)
        (module "memory" mocha.teal)
        (onLinux (module "swap" mocha.lavender))
        (module "disk" mocha.mauve)
        (module "localip" mocha.pink)
        (module "locale" mocha.peach)
        (onLinux [
          "break"
          swatchRow
          swatchRow
        ])
      ];
    }
    // lib.optionalAttrs isLinux {
      logo = {
        type = "file";
        source = ./nixos.txt;
        color = {
          "1" = "#${mocha.mauve}";
          "2" = "#${mocha.pink}";
          "3" = "#${mocha.peach}";
          "4" = "#${mocha.yellow}";
          "5" = "#${mocha.teal}";
          "6" = "#${mocha.lavender}";
        };
        padding.right = 2;
      };
    };
  };
}
