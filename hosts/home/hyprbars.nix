# Hyprland advertises server-side decorations on Wayland, so Alacritty's
# `window.decorations = "Full"` only produces Hyprland's border.  Hyprbars
# supplies the title bar that Hyprland intentionally omits.
{ pkgs, ... }:

{
  environment.etc."hypr/hyprbars.conf".text = ''
    plugin = ${pkgs.hyprbars}/lib/libhyprbars.so

    plugin {
      hyprbars {
        # Matches the Firefox toolbox / Zed title bar glass.
        bar_color = rgba(11111b8c)
        # Blur drops the bar's corner rounding in this hyprbars version.
        bar_blur = false
        bar_height = 12
        col.text = rgb(d7dae0)
        bar_title_enabled = false
        bar_text_size = 15
        bar_text_weight = 600
        bar_text_font = SF Pro Display
        bar_text_align = center
        bar_part_of_window = true
        bar_precedence_over_border = true
        on_double_click = hyprctl dispatch fullscreen 1
      }
    }

    # The plugin decorates every window by default; keep it scoped to Alacritty.
    windowrule {
      name = hide-hyprbars-outside-alacritty
      match:class = negative:^(Alacritty)$
      hyprbars:no_bar = true
    }
  '';
}
