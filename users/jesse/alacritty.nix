{ pkgs, ... }:

{
  programs.alacritty = {
    enable = true;
    package = pkgs.alacritty;

    settings = {
      bell = {
        animation = "EaseOutExpo";
        duration = 0;
      };

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

        bright = {
          black = "0x6E6C7C";
          blue = "0xA4B9EF";
          cyan = "0xF0AFE1";
          green = "0xB3E1A3";
          magenta = "0xC6AAE8";
          red = "0xE28C8C";
          white = "0xD7DAE0";
          yellow = "0xEADDA0";
        };

        cursor = {
          cursor = "0xB3E1A3";
          text = "0x1E1E28";
        };

        normal = {
          black = "0x6E6C7C";
          blue = "0xA4B9EF";
          cyan = "0xF0AFE1";
          green = "0xB3E1A3";
          magenta = "0xC6AAE8";
          red = "0xE28C8C";
          white = "0xD7DAE0";
          yellow = "0xEADDA0";
        };

        primary = {
          background = "0x1E1E28";
          foreground = "0xD7DAE0";
        };
      };

      cursor = {
        style = "Underline";
        unfocused_hollow = true;
      };

      font = {
        size = 10.0;
        normal = {
          family = "FiraCode Nerd Font";
          style = "Medium";
        };
        bold.family = "FiraCode Nerd Font";
        italic.family = "FiraCode Nerd Font";
        glyph_offset = {
          x = 0;
          y = 0;
        };
        offset = {
          x = 0;
          y = 0;
        };
      };

      hints.enabled = [
        {
          command = if pkgs.stdenv.hostPlatform.isDarwin then "open" else "xdg-open";
          post_processing = true;
          # Home Manager collapses `\\` to `\` after generating TOML.
          regex = "(ipfs:|ipns:|magnet:|mailto:|gemini:|gopher:|https:|http:|news:|file:|git:|ssh:|ftp:)[^\\u0000-\\u001F\\u007F-\\u009F<>\"\\\\s{-}\\\\^\\u27E8\\u27E9`]+";
          mouse = {
            enabled = true;
            mods = "None";
          };
        }
      ];

      keyboard.bindings = [
        {
          action = "Paste";
          key = "V";
          mods = "Control|Shift";
        }
        {
          action = "Copy";
          key = "C";
          mods = "Control|Shift";
        }
        {
          action = "Paste";
          key = "Paste";
        }
        {
          action = "Copy";
          key = "Copy";
        }
        {
          action = "Quit";
          key = "Q";
          mods = "Command";
        }
        {
          action = "Quit";
          key = "W";
          mods = "Command";
        }
        {
          action = "PasteSelection";
          key = "Insert";
          mods = "Shift";
        }
        {
          action = "ResetFontSize";
          key = "Key0";
          mods = "Control";
        }
        {
          action = "IncreaseFontSize";
          key = "Equals";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001BOH"'';
          key = "Home";
          mode = "AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[H"'';
          key = "Home";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001BOF"'';
          key = "End";
          mode = "AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[F"'';
          key = "End";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[5;2~"'';
          key = "PageUp";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[5;5~"'';
          key = "PageUp";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[5~"'';
          key = "PageUp";
        }
        {
          chars = builtins.fromJSON ''"\u001B[6;2~"'';
          key = "PageDown";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[6;5~"'';
          key = "PageDown";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[6~"'';
          key = "PageDown";
        }
        {
          chars = builtins.fromJSON ''"\u001B[Z"'';
          key = "Tab";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u007F"'';
          key = "Back";
        }
        {
          chars = builtins.fromJSON ''"\u001B\u007F"'';
          key = "Back";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[2~"'';
          key = "Insert";
        }
        {
          chars = builtins.fromJSON ''"\u001B[3~"'';
          key = "Delete";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2D"'';
          key = "Left";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5D"'';
          key = "Left";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3D"'';
          key = "Left";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[D"'';
          key = "Left";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001BOD"'';
          key = "Left";
          mode = "AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2C"'';
          key = "Right";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5C"'';
          key = "Right";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3C"'';
          key = "Right";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[C"'';
          key = "Right";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001BOC"'';
          key = "Right";
          mode = "AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2A"'';
          key = "Up";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5A"'';
          key = "Up";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3A"'';
          key = "Up";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[A"'';
          key = "Up";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001BOA"'';
          key = "Up";
          mode = "AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2B"'';
          key = "Down";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5B"'';
          key = "Down";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3B"'';
          key = "Down";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[B"'';
          key = "Down";
          mode = "~AppCursor";
        }
        {
          chars = builtins.fromJSON ''"\u001BOB"'';
          key = "Down";
          mode = "AppCursor";
        }
        {
          action = "ScrollPageUp";
          key = "F1";
        }
        {
          action = "ScrollPageDown";
          key = "F2";
        }
        {
          chars = builtins.fromJSON ''"\u001BOR"'';
          key = "F3";
        }
        {
          chars = builtins.fromJSON ''"\u001BOS"'';
          key = "F4";
        }
        {
          chars = builtins.fromJSON ''"\u001B[15~"'';
          key = "F5";
        }
        {
          chars = builtins.fromJSON ''"\u001B[17~"'';
          key = "F6";
        }
        {
          chars = builtins.fromJSON ''"\u001B[18~"'';
          key = "F7";
        }
        {
          chars = builtins.fromJSON ''"\u001B[19~"'';
          key = "F8";
        }
        {
          chars = builtins.fromJSON ''"\u001B[20~"'';
          key = "F9";
        }
        {
          chars = builtins.fromJSON ''"\u001B[21~"'';
          key = "F10";
        }
        {
          chars = builtins.fromJSON ''"\u001B[23~"'';
          key = "F11";
        }
        {
          chars = builtins.fromJSON ''"\u001B[24~"'';
          key = "F12";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2P"'';
          key = "F1";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2Q"'';
          key = "F2";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2R"'';
          key = "F3";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;2S"'';
          key = "F4";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[15;2~"'';
          key = "F5";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[17;2~"'';
          key = "F6";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[18;2~"'';
          key = "F7";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[19;2~"'';
          key = "F8";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[20;2~"'';
          key = "F9";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[21;2~"'';
          key = "F10";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[23;2~"'';
          key = "F11";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[24;2~"'';
          key = "F12";
          mods = "Shift";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5P"'';
          key = "F1";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5Q"'';
          key = "F2";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5R"'';
          key = "F3";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;5S"'';
          key = "F4";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[15;5~"'';
          key = "F5";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[17;5~"'';
          key = "F6";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[18;5~"'';
          key = "F7";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[19;5~"'';
          key = "F8";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[20;5~"'';
          key = "F9";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[21;5~"'';
          key = "F10";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[23;5~"'';
          key = "F11";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[24;5~"'';
          key = "F12";
          mods = "Control";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;6P"'';
          key = "F1";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;6Q"'';
          key = "F2";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;6R"'';
          key = "F3";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;6S"'';
          key = "F4";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[15;6~"'';
          key = "F5";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[17;6~"'';
          key = "F6";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[18;6~"'';
          key = "F7";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[19;6~"'';
          key = "F8";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[20;6~"'';
          key = "F9";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[21;6~"'';
          key = "F10";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[23;6~"'';
          key = "F11";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[24;6~"'';
          key = "F12";
          mods = "Alt";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3P"'';
          key = "F1";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3Q"'';
          key = "F2";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3R"'';
          key = "F3";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[1;3S"'';
          key = "F4";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[15;3~"'';
          key = "F5";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[17;3~"'';
          key = "F6";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[18;3~"'';
          key = "F7";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[19;3~"'';
          key = "F8";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[20;3~"'';
          key = "F9";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[21;3~"'';
          key = "F10";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[23;3~"'';
          key = "F11";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B[24;3~"'';
          key = "F12";
          mods = "Super";
        }
        {
          chars = builtins.fromJSON ''"\u001B\r"'';
          key = "Return";
          mods = "Shift";
        }
      ];

      mouse = {
        hide_when_typing = false;
        bindings = [
          {
            action = "PasteSelection";
            mouse = "Middle";
          }
        ];
      };

      scrolling = {
        history = 10000;
        multiplier = 3;
      };

      window = {
        decorations = "Full";
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
