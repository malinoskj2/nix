# Catppuccin v1 flavours plus the glass opacities the translucent apps share, so Firefox, Zed,
# Dolphin and the desktop draw from one source. Hand-copied from catppuccin/palette: reading
# config.catppuccin.sources.palette at evaluation time would be import-from-derivation.
{ lib, ... }:

let
  # 55 -> "8c": an opacity percentage as the two-digit hex alpha byte that follows rrggbb
  alphaHex =
    percent: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString ((percent * 255 + 50) / 100)));
in
{
  options.palette = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    description = "Catppuccin colours as bare `rrggbb` strings, glass opacities and colour helpers.";
    default = {
      mocha = {
        rosewater = "f5e0dc";
        flamingo = "f2cdcd";
        pink = "f5c2e7";
        mauve = "cba6f7";
        red = "f38ba8";
        maroon = "eba0ac";
        peach = "fab387";
        yellow = "f9e2af";
        green = "a6e3a1";
        teal = "94e2d5";
        sky = "89dceb";
        sapphire = "74c7ec";
        blue = "89b4fa";
        lavender = "b4befe";
        text = "cdd6f4";
        subtext1 = "bac2de";
        subtext0 = "a6adc8";
        overlay2 = "9399b2";
        overlay1 = "7f849c";
        overlay0 = "6c7086";
        surface2 = "585b70";
        surface1 = "45475a";
        surface0 = "313244";
        base = "1e1e2e";
        mantle = "181825";
        crust = "11111b";
      };

      latte = {
        rosewater = "dc8a78";
        flamingo = "dd7878";
        pink = "ea76cb";
        mauve = "8839ef";
        red = "d20f39";
        maroon = "e64553";
        peach = "fe640b";
        yellow = "df8e1d";
        green = "40a02b";
        teal = "179299";
        sky = "04a5e5";
        sapphire = "209fb5";
        blue = "1e66f5";
        lavender = "7287fd";
        text = "4c4f69";
        subtext1 = "5c5f77";
        subtext0 = "6c6f85";
        overlay2 = "7c7f93";
        overlay1 = "8c8fa1";
        overlay0 = "9ca0b0";
        surface2 = "acb0be";
        surface1 = "bcc0cc";
        surface0 = "ccd0da";
        base = "eff1f5";
        mantle = "e6e9ef";
        crust = "dce0e8";
      };

      # Opacity percentages. Window chrome (title bars, toolbars) is crust glass at `chrome`;
      # content stacks `layer` on a `root` window; text areas are `solid` so blur barely shows.
      glass = {
        chrome = 55;
        layer = 60;
        root = 80;
        solid = 90;
      };

      # "rrggbb" -> [ r g b ]
      rgb =
        hex:
        map (i: lib.fromHexString (builtins.substring i 2 hex)) [
          0
          2
          4
        ];

      # 55 -> "0.55", 60 -> "0.6"
      opacity =
        percent:
        assert percent > 0 && percent < 100;
        "0." + lib.removeSuffix "0" (lib.fixedWidthString 2 "0" (toString percent));

      inherit alphaHex;

      # "rrggbb" 55 -> "#rrggbb8c"
      withAlpha = hex: percent: "#${hex}${alphaHex percent}";
    };
  };
}
