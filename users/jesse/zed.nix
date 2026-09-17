{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  inherit (config.palette) mocha glass withAlpha;
  transparent = "#00000000";

  noParameterHints.inlay_hints.show_parameter_hints = false;

  # !biome keeps biome off in projects that happen to include it.
  typescriptServers = [
    "typescript-language-server"
    "!biome"
    "..."
  ];

  ollamaModel = {
    name = "devstral-small-2:24b";
    display_name = "Devstral Small 2 24B";
    max_tokens = 32768;
  };
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
    extraPackages = [
      pkgs.nil
      pkgs.nixfmt
    ];

    userSettings = {
      # Darwin leaves the ACP agents' modes to Zed.
      agent_servers = {
        codex-acp = {
          type = "registry";
        }
        // lib.optionalAttrs (!isDarwin) {
          default_config_options = {
            reasoning_effort = "medium";
            mode = "agent-full-access";
          };
        };
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
      };

      project_panel.dock = "left";
      outline_panel.dock = "left";
      collaboration_panel.dock = "left";
      git_panel.dock = "left";

      icon_theme = "Catppuccin Mocha";
      theme = {
        mode = "dark";
        light = "Catppuccin Latte";
        dark = "Catppuccin Mocha";
      };
      # Same two-layer idea as the Firefox userChrome, applied to the whole window so blur reads as one pane of glass.
      # Root is a crust glass layer that chrome (bars, inactive tabs) shows as-is;
      # content (active tab, toolbar, terminal) stacks a base layer on top to sit slightly lighter;
      # the editor buffer, gutter and panels are near-solid base (~98% combined with root) so blur barely reaches the text.
      # Root isn't painted under the title bar, so it needs its own crust at Firefox's tab strip alpha.
      theme_overrides."Catppuccin Mocha" = {
        "background.appearance" = "transparent";
        background = withAlpha mocha.crust glass.root;
        "title_bar.background" = withAlpha mocha.crust glass.chrome;
        "title_bar.inactive_background" = withAlpha mocha.crust glass.chrome;
        "status_bar.background" = "#${mocha.crust}";
        "tab_bar.background" = transparent;
        "tab.inactive_background" = transparent;
        "panel.background" = withAlpha mocha.mantle glass.solid;
        "tab.active_background" = withAlpha mocha.base glass.layer;
        "toolbar.background" = withAlpha mocha.base glass.layer;
        "editor.background" = withAlpha mocha.base glass.solid;
        "editor.gutter.background" = withAlpha mocha.base glass.solid;
        "scrollbar.track.background" = transparent;
        "terminal.background" = withAlpha mocha.base glass.layer;
      };

      buffer_font_size = 14;
      buffer_font_family = "Fira Code";
      buffer_font_features.calt = true;
      ui_font_size = 15;

      format_on_save = "on";
      formatter = "language_server";
      tab_size = 2;
      soft_wrap = "editor_width";
      preferred_line_length = 100;

      indent_guides.coloring = "indent_aware";
      inlay_hints.enabled = true;
      git.inline_blame.delay_ms = 600;
      terminal = {
        font_family = "Fira Code";
        font_size = 13;
        blinking = "on";
      };
      file_finder.modal_max_width = "medium";

      lsp = {
        nil.initialization_options.formatting.command = [ "nixfmt" ];
        typescript-language-server.settings.completions.completeFunctionCalls = true;
        rust-analyzer = {
          # Zed's own download is dynamically linked and may not match the installed rustc.
          binary.path = lib.getExe pkgs.rust-analyzer;
          initialization_options.check.command = "clippy";
        };
      };

      languages = {
        JavaScript = {
          language_servers = typescriptServers;
        }
        // noParameterHints;
        TypeScript = {
          language_servers = typescriptServers;
        }
        // noParameterHints;
        TSX.language_servers = typescriptServers;
        Nix.language_servers = [
          "nil"
          "..."
        ];
        Rust = {
          tab_size = 4;
        }
        // noParameterHints;
      };
    }
    // lib.optionalAttrs (!isDarwin) {
      language_models.ollama = {
        api_url = "http://localhost:11434";
        available_models = [ ollamaModel ];
      };
      agent = {
        dock = "right";
        tool_permissions.default = "allow";
        default_model = {
          provider = "ollama";
          model = ollamaModel.name;
        };
      };
    };

    userKeymaps = [
      { bindings."shift shift" = "file_finder::Toggle"; }
    ];
  };
}
