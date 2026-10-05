-- `nix` is prepended at build time.

-- This gray stays outside the palette because Catppuccin's neutrals carry a blue tint.
local SHADOW = "rgba(00000059)"

-- ("rrggbb", "aa") -> "rgba(rrggbbaa)"
local function rgba(color, alpha)
  return "rgba(" .. color .. alpha .. ")"
end

hl.config({
  cursor = {
    enable_hyprcursor = false,
  },
  decoration = {
    -- Blur is strong and vibrant because the shell's glass surfaces rely on what shows through them.
    blur = {
      noise = 0.02,
      passes = 3,
      vibrancy = 0.2,
    },
    rounding = 10,
    shadow = {
      color = SHADOW,
      range = 32,
    },
  },
  general = {
    allow_tearing = true,
    border_size = 0,
    layout = "master",
    resize_on_border = true,
  },
  misc = {
    disable_hyprland_logo = true,
    force_default_wallpaper = 0,
  },
  render = {
    direct_scanout = 2,
    expand_undersized_textures = false,
  },
})

-- j2bar's screen corners are there from the start and never move, and its on-screen display,
-- its notification banners and the fade before an idle action move by themselves.
hl.layer_rule({
  match = { namespace = "^j2bar-(screen-corner|osd|notification|idle-fade)$" },
  no_anim = true,
})
-- The panels and polkit prompt animate their capsules themselves.
hl.layer_rule({ match = { namespace = "^noctalia-panel$" }, no_anim = true })
hl.layer_rule({
  match = { namespace = "^j2bar-polkit$" },
  blur = true,
  ignore_alpha = 0.5,
  no_anim = true,
})
hl.layer_rule({ match = { namespace = "^j2bar-osd$" }, blur = true, ignore_alpha = 0.5 })
-- The lower launcher layer only draws the scrim and fades it itself. hyprrecede, below, tilts and
-- blurs what lies behind it, windows included, and the upper layer's glass samples that.
hl.layer_rule({
  match = { namespace = "^j2bar-launcher-backdrop$" },
  no_anim = true,
})
hl.layer_rule({
  match = { namespace = "^j2bar-launcher$" },
  blur = true,
  xray = false,
  ignore_alpha = 0.05,
  no_anim = true,
})

-- Springs keep their velocity when retargeted mid-animation. Overshoot is 14% for `pop` and 8%
-- for `snap`. `sway` is damped just short of critical, like a macOS Space switch: it eases in
-- with no visible bounce. `glide` is critically damped so closing windows never bounce. Springs
-- ignore `speed`.
hl.curve("pop", { type = "spring", stiffness = 600, dampening = 26, mass = 1 })
hl.curve("snap", { type = "spring", stiffness = 600, dampening = 31, mass = 1 })
hl.curve("sway", { type = "spring", stiffness = 840, dampening = 55, mass = 1 })
hl.curve("glide", { type = "spring", stiffness = 900, dampening = 60, mass = 1 })
hl.animation({ leaf = "windows", enabled = true, speed = 7, spring = "snap" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 7, spring = "pop" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 7, spring = "glide", style = "popin 80%" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 7, spring = "pop" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 7, spring = "glide" })
-- A border color fade redraws the window for a second after every focus change, which wakes the GPU
-- for no visible gain on borderless windows.
hl.animation({ leaf = "border", enabled = false })
hl.animation({ leaf = "borderangle", enabled = false })
-- `fadeOut` is off because the `windowsOut` popin already animates closing windows.
hl.animation({ leaf = "fadeOut", enabled = false })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 3, bezier = "linear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, spring = "sway" })

-- Home Manager loads the plugin before the main config. The nested sandbox imports look.lua directly.
if not hl.plugin.hyprglass then
  hl.plugin.load(nix.j2barPlugin)
end

-- Windows are borderless, so the bundled plugin dips the focused one to make focus changes visible.

hl.config({
  plugin = {
    hyprfocus = {
      keyboard_focus_animation = "shrink",
      mouse_focus_animation = "shrink",
      shrink_percentage = 0.99,
      -- The file chooser dips through hyprsheet instead, which scales its frame rather than
      -- resizing it, so its buttons don't lay out again at each size.
      class = "^(?!xdg-desktop-portal-gtk$).*$",
    },
  },
})

hl.curve("hyprfocusDip", { type = "bezier", points = { { 0.25, 1 }, { 0.5, 1 } } })
hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.5, bezier = "hyprfocusDip" })
hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 4, bezier = "hyprfocusDip" })

-- Alacritty and mpv have no title bar of their own, so the bundled plugin gives them a thin one to
-- grab and double-click.

hl.config({
  plugin = {
    hyprbars = {
      bar_blur = false,
      bar_color = rgba(nix.palette.crust, nix.alpha.chrome),
      bar_height = 12,
      bar_part_of_window = true,
      bar_precedence_over_border = true,
      bar_title_enabled = false,
      -- Under a Lua config, `hyprctl dispatch` takes an `hl.dsp` expression.
      on_double_click = nix.hyprctl .. [[ dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
    },
  },
})

-- The bundled glass effect draws j2bar's panels in the compositor, where it can see behind layers.

local glass = hl.plugin.hyprglass
if glass then
  glass.config({ enabled = false, default_theme = "dark", layers = { enabled = true } })

  -- Fitted to macOS 27's Clear widget glass: it darkens and saturates what's behind it and refracts
  -- almost nothing, so the panels' own Catppuccin fill still sets the tone.
  glass.preset("panel", {
    adaptive_boost = 0.0,
    adaptive_dim = 0.0,
    brightness = 0.91,
    chromatic_aberration = 0.0,
    contrast = 1.0,
    edge_thickness = 0.01,
    fresnel_strength = 0.0,
    lens_distortion = 0.0,
    refraction_strength = 0.05,
    saturation = 1.33,
    specular_strength = 0.0,
    tint_color = 0x00000000,
    vibrancy = 0.0,
  })

  -- The launcher sends two separate glass regions: the container and its search capsule. The
  -- capsule's radius clamps to half its height; the container keeps its 36 px corners.
  glass.layer("j2bar-launcher", {
    preset = "panel",
    mask_mode = "region",
    corner_radius = 36,
    rounding_power = 2.0,
    rim_light = 2.6,
    rim_shadow = 2.7,
    live_resample = true,
    gleam_colors = {
      nix.palette.peach,
      nix.palette.teal,
      nix.palette.lavender,
      nix.palette.mauve,
    },
    gleam_strength = 1.0,
    gleam_width = 1.2,
    gleam_length = 0.6,
    gleam_duration = 1.2,
    gleam_delay = 0.1,
    gleam_rest = 0.3,
  })

  -- Match the radius of each capsule j2bar draws in its blur region.
  for _, namespace in ipairs({ "noctalia-panel", "j2bar-polkit", "j2bar-notification" }) do
    glass.layer(namespace, {
      preset = "panel",
      mask_mode = "region",
      corner_radius = 18,
      rounding_power = 2.0,
      rim_light = 2.6,
      rim_shadow = 2.7,
      live_resample = namespace == "noctalia-panel",
    })
  end

  glass.layer("j2bar-osd", {
    preset = "panel",
    mask_mode = "region",
    corner_radius = 22,
    rounding_power = 2.0,
    rim_light = 2.6,
    rim_shadow = 2.7,
  })
end

-- While j2bar's launcher, a picker or its polkit prompt is open, hyprrecede leans the windows on
-- that monitor back, shades them from the top and blurs everything below the shell's layers, the
-- way Liquid34 pushes the window behind a modal back. The launcher's backdrop layer is how it
-- knows: j2bar maps it with the launcher or a picker and unmaps it the moment either is dismissed,
-- so the windows spring back while the panel is still leaving.

hl.config({
  plugin = {
    hyprrecede = {
      namespace = "^j2bar-(launcher-backdrop|polkit)$",
      angle = 16,
      scale = 0.86,
      perspective = 1400,
      shade = 0.62,
      blur = 1,
    },
  },
})

-- Liquid34's transitions: the tilt takes 620 ms on its `--ease-settle`, the shade 500 ms on CSS's
-- `ease`. The blur finishes in 240 ms, during the launcher reveal, without a spring's settling
-- tail after the launcher is already fully visible.
hl.curve("settle", { type = "bezier", points = { { 0.3, 1.25 }, { 0.4, 1 } } })
hl.curve("ease", { type = "bezier", points = { { 0.25, 0.1 }, { 0.25, 1 } } })
hl.animation({ leaf = "hyprrecedeTilt", enabled = true, speed = 6.2, bezier = "settle" })
hl.animation({ leaf = "hyprrecedeShade", enabled = true, speed = 5, bezier = "ease" })
hl.animation({ leaf = "hyprrecedeBlur", enabled = true, speed = 2.4, bezier = "ease" })
