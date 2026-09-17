{
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  coloredModule = type: keyColor: { inherit type keyColor; };
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      display = {
        separator = "  ";
        color = {
          title = "#cba6f7";
          output = "#cdd6f4";
          separator = "#6c7086";
        };
      };

      modules = [
        "title"
        "separator"
        (coloredModule "os" "#cba6f7")
        (coloredModule "host" "#f5c2e7")
      ]
      ++ lib.optionals isLinux [
        (coloredModule "kernel" "#fab387")
      ]
      ++ [
        (coloredModule "uptime" "#f9e2af")
      ]
      ++ lib.optionals isLinux [
        (coloredModule "packages" "#94e2d5")
      ]
      ++ [
        (coloredModule "shell" "#b4befe")
        (coloredModule "display" "#cba6f7")
      ]
      ++ lib.optionals isLinux [
        (coloredModule "wm" "#f5c2e7")
        (coloredModule "theme" "#fab387")
        (coloredModule "icons" "#f9e2af")
        (coloredModule "font" "#94e2d5")
        (coloredModule "cursor" "#b4befe")
      ]
      ++ [
        (coloredModule "terminal" (if isLinux then "#cba6f7" else "#f5c2e7"))
      ]
      ++ lib.optionals isLinux [
        (coloredModule "terminalfont" "#f5c2e7")
      ]
      ++ [
        (coloredModule "cpu" "#fab387")
        (coloredModule "gpu" "#f9e2af")
        (coloredModule "memory" "#94e2d5")
      ]
      ++ lib.optionals isLinux [
        (coloredModule "swap" "#b4befe")
      ]
      ++ [
        (coloredModule "disk" "#cba6f7")
        (coloredModule "localip" "#f5c2e7")
        (coloredModule "locale" "#fab387")
      ]
      ++ lib.optionals isLinux [
        "break"
        # The colors module only shows the 16 ANSI colors, which have no peach.
        {
          type = "custom";
          format = "{#48;2;243;139;168}   {#48;2;250;179;135}   {#48;2;249;226;175}   {#48;2;166;227;161}   {#48;2;148;226;213}   {#48;2;137;180;250}   {#48;2;180;190;254}   {#48;2;203;166;247}   {#48;2;245;194;231}   {#}";
        }
        {
          type = "custom";
          format = "{#48;2;243;139;168}   {#48;2;250;179;135}   {#48;2;249;226;175}   {#48;2;166;227;161}   {#48;2;148;226;213}   {#48;2;137;180;250}   {#48;2;180;190;254}   {#48;2;203;166;247}   {#48;2;245;194;231}   {#}";
        }
      ];
    }
    // lib.optionalAttrs isLinux {
      logo = {
        type = "file";
        source = ./fastfetch/nixos.txt;
        color = {
          "1" = "#cba6f7";
          "2" = "#f5c2e7";
          "3" = "#fab387";
          "4" = "#f9e2af";
          "5" = "#94e2d5";
          "6" = "#b4befe";
        };
        padding.right = 2;
      };
    };
  };
}
