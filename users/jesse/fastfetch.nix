{
  programs.fastfetch = {
    enable = true;

    settings = {
      # Catppuccin Mocha, matching the noctalia snowflake arms
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
        padding = {
          right = 2;
        };
      };

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
        {
          type = "os";
          keyColor = "#cba6f7";
        }
        {
          type = "host";
          keyColor = "#f5c2e7";
        }
        {
          type = "kernel";
          keyColor = "#fab387";
        }
        {
          type = "uptime";
          keyColor = "#f9e2af";
        }
        {
          type = "packages";
          keyColor = "#94e2d5";
        }
        {
          type = "shell";
          keyColor = "#b4befe";
        }
        {
          type = "display";
          keyColor = "#cba6f7";
        }
        {
          type = "wm";
          keyColor = "#f5c2e7";
        }
        {
          type = "theme";
          keyColor = "#fab387";
        }
        {
          type = "icons";
          keyColor = "#f9e2af";
        }
        {
          type = "font";
          keyColor = "#94e2d5";
        }
        {
          type = "cursor";
          keyColor = "#b4befe";
        }
        {
          type = "terminal";
          keyColor = "#cba6f7";
        }
        {
          type = "terminalfont";
          keyColor = "#f5c2e7";
        }
        {
          type = "cpu";
          keyColor = "#fab387";
        }
        {
          type = "gpu";
          keyColor = "#f9e2af";
        }
        {
          type = "memory";
          keyColor = "#94e2d5";
        }
        {
          type = "swap";
          keyColor = "#b4befe";
        }
        {
          type = "disk";
          keyColor = "#cba6f7";
        }
        {
          type = "localip";
          keyColor = "#f5c2e7";
        }
        {
          type = "locale";
          keyColor = "#fab387";
        }
        "break"
        # The colors module only shows the 16 ANSI colors, which have no peach
        {
          type = "custom";
          format = "{#48;2;243;139;168}   {#48;2;250;179;135}   {#48;2;249;226;175}   {#48;2;166;227;161}   {#48;2;148;226;213}   {#48;2;137;180;250}   {#48;2;180;190;254}   {#48;2;203;166;247}   {#48;2;245;194;231}   {#}";
        }
        {
          type = "custom";
          format = "{#48;2;243;139;168}   {#48;2;250;179;135}   {#48;2;249;226;175}   {#48;2;166;227;161}   {#48;2;148;226;213}   {#48;2;137;180;250}   {#48;2;180;190;254}   {#48;2;203;166;247}   {#48;2;245;194;231}   {#}";
        }
      ];
    };
  };
}
