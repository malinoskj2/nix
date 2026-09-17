{ lib, pkgs, ... }:

let
  esc = builtins.fromJSON ''"\u001B"'';

  # Pre-v1 Catppuccin terminal colours. Alacritty was never moved to the v1 Mocha palette in
  # palette.nix, and doing so would visibly change the terminal.
  legacyColors = rec {
    background = "0x1E1E28";
    foreground = "0xD7DAE0";
    ansi = {
      black = "0x6E6C7C";
      red = "0xE28C8C";
      green = "0xB3E1A3";
      yellow = "0xEADDA0";
      blue = "0xA4B9EF";
      magenta = "0xC6AAE8";
      cyan = "0xF0AFE1";
      white = foreground;
    };
  };
in
{
  programs.alacritty = {
    enable = true;

    settings = {
      colors = {
        draw_bold_text_with_bright_colors = true;

        indexed_colors = [
          {
            color = "0xECBFBD";
            index = 16;
          }
          {
            color = "0x3E4058";
            index = 17;
          }
        ];

        normal = legacyColors.ansi;
        bright = legacyColors.ansi;

        cursor = {
          cursor = legacyColors.ansi.green;
          text = legacyColors.background;
        };

        primary = {
          inherit (legacyColors) background foreground;
        };
      };

      cursor.style = "Underline";

      font = {
        size = 10.0;
        normal = {
          family = "FiraCode Nerd Font";
          style = "Medium";
        };
      };

      keyboard.bindings = [
        {
          key = "F1";
          action = "ScrollPageUp";
        }
        {
          key = "F2";
          action = "ScrollPageDown";
        }
        # Pass Shift+PageUp/PageDown to the application instead of scrolling.
        {
          key = "PageUp";
          mods = "Shift";
          chars = "${esc}[5;2~";
        }
        {
          key = "PageDown";
          mods = "Shift";
          chars = "${esc}[6;2~";
        }
        {
          key = "Enter";
          mods = "Shift";
          chars = "${esc}\r";
        }
      ]
      # Alacritty's macOS defaults use Command for these.
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        {
          key = "V";
          mods = "Control|Shift";
          action = "Paste";
        }
        {
          key = "C";
          mods = "Control|Shift";
          action = "Copy";
        }
        {
          key = "Insert";
          mods = "Shift";
          action = "PasteSelection";
        }
        {
          key = "0";
          mods = "Control";
          action = "ResetFontSize";
        }
        {
          key = "=";
          mods = "Control";
          action = "IncreaseFontSize";
        }
        {
          key = "-";
          mods = "Control";
          action = "DecreaseFontSize";
        }
      ];

      window = {
        dynamic_padding = true;
        dimensions = {
          columns = 80;
          lines = 40;
        };
        padding = {
          x = 13;
          y = 13;
        };
      };
    };
  };
}
