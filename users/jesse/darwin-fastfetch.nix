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
        {
          type = "os";
          keyColor = "#cba6f7";
        }
        {
          type = "host";
          keyColor = "#f5c2e7";
        }
        {
          type = "uptime";
          keyColor = "#f9e2af";
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
          type = "terminal";
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
      ];
    };
  };
}
