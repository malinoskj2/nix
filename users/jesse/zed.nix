{ lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
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

    # Zed Settings
    # For reference: https://zed.dev/docs/configuring-zed
    userSettings = {
      # --- Theme ---
      # Requires the "Catppuccin" extension: command palette → "zed: extensions" → search "Catppuccin"
      cli_default_open_behavior = "existing_window";
      # Darwin gets both ACP integrations without repository-forced permission
      # modes; the existing Linux defaults remain unchanged.
      agent_servers = {
        "codex-acp" = {
          type = "registry";
        }
        // lib.optionalAttrs (!isDarwin) {
          default_config_options = {
            reasoning_effort = "medium";
            mode = "agent-full-access";
          };
        };
        "claude-acp" = {
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
      project_panel = {
        dock = "left";
      };
      outline_panel = {
        dock = "left";
      };
      collaboration_panel = {
        dock = "left";
      };
      git_panel = {
        dock = "left";
      };
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
      theme_overrides = {
        "Catppuccin Mocha" = {
          "background.appearance" = "transparent";
          background = "#11111bcc";
          "title_bar.background" = "#11111b8c";
          "title_bar.inactive_background" = "#11111b8c";
          "status_bar.background" = "#11111b";
          "tab_bar.background" = "#00000000";
          "tab.inactive_background" = "#00000000";
          "panel.background" = "#181825e6";
          "tab.active_background" = "#1e1e2e99";
          "toolbar.background" = "#1e1e2e99";
          "editor.background" = "#1e1e2ee6";
          "editor.gutter.background" = "#1e1e2ee6";
          "scrollbar.track.background" = "#00000000";
          "terminal.background" = "#1e1e2e99";
        };
      };
      # --- Fonts ---
      buffer_font_size = 14;
      buffer_font_family = "Fira Code";
      buffer_font_features = {
        # Enable Fira Code ligatures (e.g. => !== -> <=)
        calt = true;
      };
      ui_font_size = 15;
      # --- Editor Behaviour ---
      autosave = "off";
      format_on_save = "on";
      formatter = "language_server";
      auto_indent = true;
      tab_size = 2;
      hard_tabs = false;
      soft_wrap = "editor_width";
      preferred_line_length = 100;
      show_whitespaces = "selection";
      cursor_blink = true;
      hover_popover_enabled = true;
      show_completions_on_input = true;
      show_completion_documentation = true;
      use_autoclose = true;
      always_treat_brackets_as_autoclosed = false;
      # --- Indent Guides ---
      indent_guides = {
        enabled = true;
        line_width = 1;
        coloring = "indent_aware";
      };
      # --- Gutter / Line Numbers ---
      gutter = {
        line_numbers = true;
        code_actions = true;
        runnables = true;
        folds = true;
      };
      relative_line_numbers = "disabled";
      # --- Inlay Hints ---
      inlay_hints = {
        enabled = true;
        show_type_hints = true;
        show_parameter_hints = true;
        show_other_hints = true;
      };
      # --- Scrollbar ---
      scrollbar = {
        show = "auto";
        diagnostics = "all";
        git_diff = true;
        search_results = true;
        selected_symbol = true;
      };
      # --- Git ---
      git = {
        git_gutter = "tracked_files";
        inline_blame = {
          enabled = true;
          delay_ms = 600;
        };
      };
      # --- Terminal ---
      terminal = {
        font_family = "Fira Code";
        font_size = 13;
        shell = "system";
        working_directory = "current_project_directory";
        blinking = "on";
      };
      # --- File Finder ---
      file_finder = {
        modal_max_width = "medium";
      };
      # --- LSP config ---
      # JavaScript / TypeScript:
      #   Zed auto-downloads typescript-language-server via npm — nothing to install.
      #
      # Bash:
      #   Zed auto-downloads bash-language-server via npm — nothing to install.
      #
      # Nix:
      #   Zed does NOT bundle a Nix LSP; nil and nixfmt come from extraPackages.
      #   You also need the "Nix" extension from the Zed extension marketplace.
      lsp = {
        nil = {
          initialization_options = {
            formatting = {
              command = [ "nixfmt" ];
            };
          };
        };
        # Swap the language_servers entry in the Nix section below to "nixd" if you prefer it over nil
        nixd = {
          initialization_options = {
            formatting = {
              command = [ "nixfmt" ];
            };
          };
        };
        "typescript-language-server" = {
          settings = {
            completions = {
              completeFunctionCalls = true;
            };
          };
        };
        # Use the nix-provided rust-analyzer so it matches the installed rustc,
        # instead of the dynamically-linked one Zed downloads for itself
        "rust-analyzer" = {
          binary = {
            path = lib.getExe pkgs.rust-analyzer;
            arguments = [ ];
          };
          initialization_options = {
            check = {
              command = "clippy";
            };
          };
        };
      };
      # --- Per-language settings ---
      languages = {
        JavaScript = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          # typescript-language-server is auto-downloaded by Zed
          # !biome disables biome if it happens to be present in a project
          language_servers = [
            "typescript-language-server"
            "!biome"
            "..."
          ];
          enable_language_server = true;
          inlay_hints = {
            enabled = true;
            show_type_hints = true;
            show_parameter_hints = false;
            show_other_hints = true;
          };
        };
        JSX = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          language_servers = [
            "typescript-language-server"
            "!biome"
            "..."
          ];
          enable_language_server = true;
        };
        TypeScript = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          language_servers = [
            "typescript-language-server"
            "!biome"
            "..."
          ];
          enable_language_server = true;
          inlay_hints = {
            enabled = true;
            show_type_hints = true;
            show_parameter_hints = false;
            show_other_hints = true;
          };
        };
        TSX = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          language_servers = [
            "typescript-language-server"
            "!biome"
            "..."
          ];
          enable_language_server = true;
        };
        Nix = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          # Needs the Zed "Nix" extension; nil comes from extraPackages
          language_servers = [
            "nil"
            "..."
          ];
          enable_language_server = true;
        };
        Bash = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          # bash-language-server is auto-downloaded by Zed
          language_servers = [
            "bash-language-server"
            "..."
          ];
          enable_language_server = true;
        };
        "Shell Script" = {
          tab_size = 2;
          format_on_save = "on";
          formatter = "language_server";
          language_servers = [
            "bash-language-server"
            "..."
          ];
          enable_language_server = true;
        };
        Rust = {
          tab_size = 4;
          format_on_save = "on";
          formatter = "language_server";
          # Rust support is built into Zed, no extension needed
          language_servers = [
            "rust-analyzer"
            "..."
          ];
          enable_language_server = true;
          inlay_hints = {
            enabled = true;
            show_type_hints = true;
            show_parameter_hints = false;
            show_other_hints = true;
          };
        };
      };
    }
    // lib.optionalAttrs (!isDarwin) {
      language_models.ollama = {
        api_url = "http://localhost:11434";
        available_models = [
          {
            name = "devstral-small-2:24b";
            display_name = "Devstral Small 2 24B";
            max_tokens = 32768;
          }
        ];
      };
      agent = {
        dock = "right";
        always_allow_tool_actions = true;
        default_model = {
          provider = "ollama";
          model = "devstral-small-2:24b";
        };
        model_parameters = [
          {
            provider = "ollama";
            model = "devstral-small-2:24b";
            display_name = "Devstral Small 2 24B";
            max_tokens = 32768;
          }
        ];
      };
    };

    userKeymaps = [
      {
        bindings = {
          "shift shift" = "file_finder::Toggle";
        };
      }
    ];
  };
}
