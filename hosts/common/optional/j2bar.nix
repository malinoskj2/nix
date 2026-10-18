{ inputs, lib, ... }:
let
  spring = stiffness: dampening: {
    type = "spring";
    inherit stiffness dampening;
    mass = 1.0;
  };
  bezier = points: {
    type = "bezier";
    inherit points;
  };
  animation = speed: curve: {
    enabled = true;
    inherit speed curve;
  };
  panel = radius: live: {
    preset = "panel";
    mask_mode = "region";
    corner_radius = radius;
    rounding_power = 2.0;
    rim_light = 2.6;
    rim_shadow = 2.7;
    live_resample = live;
  };
in
{
  imports = [ inputs.j2bar.nixosModules.default ];

  programs.j2bar = {
    enable = true;
    hyprlandPlugin.enable = true;
    gameEngine.enable = true;
    settings = {
      output = "DP-2";
      wallpaper.enabled = true;
      assistant.config_path = "/home/jesse/nix/hosts/home/configuration.nix";
      game = {
        enabled = true;
        mute_workspace_5_audio = true;
      };
      # Exact visual policy previously declared in look.lua and hyprland.lua.
      # Input, output topology, low-latency game rules and plugin load remain Lua-owned.
      effects = {
        enabled = true;
        compositor = {
          rounding = 10;
          border_size = 0;
          blur_noise = 0.02;
          blur_passes = 3;
          blur_vibrancy = 0.2;
          shadow_color = "00000059";
          shadow_range = 32;
        };
        focus = {
          keyboard_focus_animation = "shrink";
          mouse_focus_animation = "shrink";
          shrink_percentage = 0.99;
          class = "^(?!xdg-desktop-portal-gtk$).*$";
        };
        bars = {
          classes = "^(Alacritty|mpv)$";
          bar_blur = false;
          bar_color = "11111b8c";
          bar_height = 12;
          bar_part_of_window = true;
          bar_precedence_over_border = true;
          bar_title_enabled = false;
          on_double_click = "maximize";
        };
        sheet = {
          class = "^(xdg-desktop-portal-gtk)$";
          parent_share = 0.75;
          min_size = [
            700
            450
          ];
          dip = 0.99;
        };
        recede = {
          namespace = "^j2bar-(launcher-backdrop|polkit)$";
          angle = 16.0;
          scale = 0.86;
          perspective = 1400.0;
          shade = 0.62;
          blur = 1.0;
        };
        glass = {
          enabled = false;
          default_theme = "dark";
          presets.panel.values = {
            adaptive_boost = 0.0;
            adaptive_dim = 0.0;
            brightness = 0.91;
            chromatic_aberration = 0.0;
            contrast = 1.0;
            edge_thickness = 0.01;
            fresnel_strength = 0.0;
            lens_distortion = 0.0;
            refraction_strength = 0.05;
            saturation = 1.33;
            specular_strength = 0.0;
            tint_color = "00000000";
            vibrancy = 0.0;
          };
          layers = {
            enabled = true;
            entries = {
              "j2bar-launcher" = (panel 36.0 true) // {
                gleam_colors = [
                  "fab387"
                  "94e2d5"
                  "b4befe"
                  "cba6f7"
                ];
                gleam_strength = 1.0;
                gleam_width = 1.2;
                gleam_length = 0.6;
                gleam_duration = 1.2;
                gleam_delay = 0.1;
                gleam_rest = 0.3;
              };
              "noctalia-panel" = panel 18.0 true;
              "j2bar-polkit" = panel 18.0 false;
              "j2bar-notification" = panel 18.0 false;
              "j2bar-osd" = panel 22.0 false;
            };
          };
        };
        layer_rules = {
          shell-static = {
            namespace = "^j2bar-(screen-corner|osd|notification|idle-fade)$";
            no_anim = true;
          };
          panel = {
            namespace = "^noctalia-panel$";
            no_anim = true;
          };
          polkit = {
            namespace = "^j2bar-polkit$";
            no_anim = true;
            blur = true;
            ignore_alpha = 0.5;
          };
          osd = {
            namespace = "^j2bar-osd$";
            blur = true;
            ignore_alpha = 0.5;
          };
          launcher-backdrop = {
            namespace = "^j2bar-launcher-backdrop$";
            no_anim = true;
          };
          launcher = {
            namespace = "^j2bar-launcher$";
            no_anim = true;
            blur = true;
            xray = false;
            ignore_alpha = 0.05;
          };
        };
        curves = {
          pop = spring 600.0 26.0;
          snap = spring 600.0 31.0;
          sway = spring 840.0 55.0;
          glide = spring 900.0 60.0;
          land = spring 625.0 42.5;
          hyprfocusDip = bezier [
            [
              0.25
              1.0
            ]
            [
              0.5
              1.0
            ]
          ];
          settle = bezier [
            [
              0.3
              1.25
            ]
            [
              0.4
              1.0
            ]
          ];
          ease = bezier [
            [
              0.25
              0.1
            ]
            [
              0.25
              1.0
            ]
          ];
        };
        animations = {
          windows = animation 7.0 "snap";
          windowsIn = animation 7.0 "pop";
          windowsOut = (animation 7.0 "glide") // {
            style = "popin 80%";
          };
          layersIn = animation 7.0 "pop";
          layersOut = animation 7.0 "glide";
          border.enabled = false;
          borderangle.enabled = false;
          fadeOut.enabled = false;
          fadeSwitch = animation 3.0 "linear";
          workspaces = animation 6.0 "sway";
          hyprfocusIn = animation 1.5 "hyprfocusDip";
          hyprfocusOut = animation 4.0 "hyprfocusDip";
          hyprsheetIn = animation 7.0 "land";
          hyprsheetOut = animation 7.0 "land";
          hyprrecedeTilt = animation 6.2 "settle";
          hyprrecedeShade = animation 5.0 "ease";
          hyprrecedeBlur = animation 2.4 "ease";
        };
      };
    };
  };

  # j2bar is launched by hand from a local build; the unit only supplies its environment.
  systemd.user.services.j2bar.wantedBy = lib.mkForce [ ];

  # Keep the existing TTY recovery path if the native locker cannot start.
  programs.hyprlock.enable = true;
}
