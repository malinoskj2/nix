{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.palette) mocha rgb;
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  mkModule = type: color: {
    inherit type;
    keyColor = "#${color}";
  };

  onLinux = lib.optional isLinux;
  swatch = color: "{#48;2;${lib.concatMapStringsSep ";" toString (rgb color)}}   ";

  # The colors module only shows the 16 ANSI colors, which have no peach.
  # Two identical rows make each swatch a block rather than a thin stripe.
  swatchRow = {
    type = "custom";

    format =
      lib.concatMapStrings swatch [
        mocha.red
        mocha.peach
        mocha.yellow
        mocha.green
        mocha.teal
        mocha.blue
        mocha.lavender
        mocha.mauve
        mocha.pink
      ]
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

      modules = lib.flatten [
        "title"
        "separator"
        (mkModule "os" mocha.mauve)
        (mkModule "host" mocha.pink)
        (onLinux (mkModule "kernel" mocha.peach))
        (mkModule "uptime" mocha.yellow)
        (onLinux (mkModule "packages" mocha.teal))
        (mkModule "shell" mocha.lavender)
        (mkModule "display" mocha.mauve)
        (onLinux [
          (mkModule "wm" mocha.pink)
          (mkModule "theme" mocha.peach)
          (mkModule "icons" mocha.yellow)
          (mkModule "font" mocha.teal)
          (mkModule "cursor" mocha.lavender)
        ])
        # Pink follows display's mauve on macOS, where the Linux-only modules between them are gone.
        (mkModule "terminal" (if isLinux then mocha.mauve else mocha.pink))
        (onLinux (mkModule "terminalfont" mocha.pink))
        (mkModule "cpu" mocha.peach)
        (mkModule "gpu" mocha.yellow)
        (mkModule "memory" mocha.teal)
        (onLinux (mkModule "swap" mocha.lavender))
        (mkModule "disk" mocha.mauve)
        (mkModule "localip" mocha.pink)
        (mkModule "locale" mocha.peach)
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
        padding.right = 2;

        color = {
          "1" = "#${mocha.mauve}";
          "2" = "#${mocha.pink}";
          "3" = "#${mocha.peach}";
          "4" = "#${mocha.yellow}";
          "5" = "#${mocha.teal}";
          "6" = "#${mocha.lavender}";
        };
      };
    };
  };
}
