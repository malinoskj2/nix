{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.palette) glass mocha withAlpha;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  darkTheme = "Catppuccin Mocha";
  transparent = "#00000000";
  noParameterHints.inlay_hints.show_parameter_hints = false;

  ollamaModel = {
    name = "devstral-small-2:24b";
    display_name = "Devstral Small 2 24B";
    max_tokens = 32768;
  };

  # !biome keeps biome off in projects that happen to include it.
  typescriptServers = [
    "typescript-language-server"
    "!biome"
    "..."
  ];
in
{
  programs.zed-editor = {
    enable = true;
    package = pkgs.unstable.zed-editor;

    extensions = [
      "catppuccin"
      "catppuccin-icons"
      "nix"
    ];

    extraPackages = with pkgs; [
      nil
      nixfmt
    ];

    userSettings = {
      agent_servers = {
        claude-acp = {
          type = "registry";
        }
        // lib.optionalAttrs (!isDarwin) {
          default_config_options = {
            model = "haiku";
            mode = "auto";
            effort = "max";
          };
        };

        codex-acp = {
          type = "registry";
        }
        // lib.optionalAttrs (!isDarwin) {
          default_config_options = {
            reasoning_effort = "medium";
            mode = "agent-full-access";
          };
        };
      };

      collaboration_panel.dock = "left";
      git_panel.dock = "left";
      outline_panel.dock = "left";
      project_panel.dock = "left";

      icon_theme = darkTheme;

      theme = {
        mode = "dark";
        light = "Catppuccin Latte";
        dark = darkTheme;
      };

      # Two glass layers span the window, as in Firefox's userChrome, so blur reads as one pane.
      theme_overrides.${darkTheme} = {
        "background.appearance" = "transparent";
        background = withAlpha mocha.crust glass.root;

        # Zed doesn't paint the root under the title bar, so the bar carries its own crust glass.
        "title_bar.background" = withAlpha mocha.crust glass.chrome;
        "title_bar.inactive_background" = withAlpha mocha.crust glass.chrome;

        # The tab bar, inactive tabs and scrollbar track show the root as-is.
        "tab_bar.background" = transparent;
        "tab.inactive_background" = transparent;
        "scrollbar.track.background" = transparent;

        "tab.active_background" = withAlpha mocha.base glass.layer;
        "toolbar.background" = withAlpha mocha.base glass.layer;
        "terminal.background" = withAlpha mocha.base glass.layer;

        # Text areas are near-solid so blur barely reaches the text; the status bar is solid.
        "editor.background" = withAlpha mocha.base glass.solid;
        "editor.gutter.background" = withAlpha mocha.base glass.solid;
        "panel.background" = withAlpha mocha.mantle glass.solid;
        "status_bar.background" = "#${mocha.crust}";
      };

      buffer_font_family = "Fira Code";
      buffer_font_features.calt = true;
      buffer_font_size = 14;
      ui_font_size = 15;

      terminal = {
        font_family = "Fira Code";
        font_size = 13;
        blinking = "on";
      };

      file_finder.modal_max_width = "medium";
      format_on_save = "on";
      formatter = "language_server";
      git.inline_blame.delay_ms = 600;
      indent_guides.coloring = "indent_aware";
      inlay_hints.enabled = true;
      preferred_line_length = 100;
      soft_wrap = "editor_width";
      tab_size = 2;

      lsp = {
        nil.initialization_options.formatting.command = [ "nixfmt" ];

        rust-analyzer = {
          # Zed's own download is dynamically linked and may not match the installed rustc.
          binary.path = lib.getExe pkgs.rust-analyzer;
          initialization_options.check.command = "clippy";
        };

        typescript-language-server.settings.completions.completeFunctionCalls = true;
      };

      languages = {
        JavaScript = noParameterHints // {
          language_servers = typescriptServers;
        };

        Nix.language_servers = [
          "nil"
          "..."
        ];

        Rust = noParameterHints // {
          tab_size = 4;
        };

        TSX.language_servers = typescriptServers;

        TypeScript = noParameterHints // {
          language_servers = typescriptServers;
        };
      };
    }
    // lib.optionalAttrs (!isDarwin) {
      agent = {
        dock = "right";
        tool_permissions.default = "allow";

        default_model = {
          provider = "ollama";
          model = ollamaModel.name;
        };
      };

      language_models.ollama = {
        api_url = "http://localhost:11434";
        available_models = [ ollamaModel ];
      };
    };

    userKeymaps = [
      { bindings."shift shift" = "file_finder::Toggle"; }
    ];
  };
}
