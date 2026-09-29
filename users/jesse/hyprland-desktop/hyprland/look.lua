-- `nix` is prepended at build time.

-- This gray stays outside the palette because Catppuccin's neutrals carry a blue tint.
local SHADOW = "rgba(00000059)"

-- j2bar's bar, tooltip, panels and control button keep the layer namespaces they had in Noctalia,
-- which it was built to replace surface for surface. These omit the `noctalia-` prefix, which
-- `noctalia_layers` adds. `osd` is the tooltip; the on-screen display is `j2bar-osd`.
local GLASS_LAYERS = { "bar-.+" }
local TRANSLUCENT_LAYERS = { "osd" }

-- ("rrggbb", "aa") -> "rgba(rrggbbaa)"
local function rgba(color, alpha)
  return "rgba(" .. color .. alpha .. ")"
end

local function noctalia_layers(...)
  local names = {}
  for _, group in ipairs({ ... }) do
    table.move(group, 1, #group, #names + 1, names)
  end
  return "^noctalia-(" .. table.concat(names, "|") .. ")$"
end

hl.config({
  cursor = {
    enable_hyprcursor = false,
  },
  decoration = {
    -- Blur is strong and vibrant because j2bar's glass surfaces rely on what shows through them.
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

-- j2bar draws glass, so its layers need blur; `ignore_alpha` keeps it off transparent margins.
hl.layer_rule({
  match = { namespace = noctalia_layers(GLASS_LAYERS, TRANSLUCENT_LAYERS) },
  blur = true,
  blur_popups = true,
  no_anim = true,
})

hl.layer_rule({ match = { namespace = noctalia_layers(TRANSLUCENT_LAYERS) }, ignore_alpha = 0.5 })
hl.layer_rule({ match = { namespace = noctalia_layers(GLASS_LAYERS) }, ignore_alpha = 0.02 })
hl.layer_rule({ match = { namespace = noctalia_layers(GLASS_LAYERS) }, xray = true })

-- Floating panels scale in and out like windows.
hl.layer_rule({ match = { namespace = noctalia_layers({ "panel" }) }, animation = "popin 80%" })

-- j2bar's screen corners are there from the start and never move, and its on-screen display,
-- its notification banners and the fade before an idle action move by themselves.
hl.layer_rule({
  match = { namespace = "^j2bar-(screen-corner|osd|notification|idle-fade)$" },
  no_anim = true,
})
-- j2bar's polkit prompt is a panel in the middle of the screen.
hl.layer_rule({
  match = { namespace = "^j2bar-polkit$" },
  blur = true,
  ignore_alpha = 0.5,
  animation = "popin 80%",
})
hl.layer_rule({ match = { namespace = "^j2bar-osd$" }, blur = true, ignore_alpha = 0.5 })
-- j2bar's launcher covers the output and dims it, so the whole desktop blurs behind it.
hl.layer_rule({ match = { namespace = "^j2bar-launcher$" }, blur = true, animation = "fade" })

-- j2bar's control button, under the namespace of the Noctalia desktop widget it replaced.
hl.layer_rule({
  match = { namespace = "^noctalia-desktop-widget-jesse/control-button:.+$" },
  blur = true,
  ignore_alpha = 0.05,
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

-- Windows are borderless, so hyprfocus dips the focused one to make focus changes visible.
hl.plugin.load(nix.hyprfocus)

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

-- Alacritty and mpv have no title bar of their own, so hyprbars gives them a thin one to grab and
-- double-click.
hl.plugin.load(nix.hyprbars)

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

-- hyprglass draws j2bar's panels as refractive glass in the compositor, the only place that can
-- see what lies behind a layer. Windows stay as they are.
hl.plugin.load(nix.hyprglass)

local glass = hl.plugin.hyprglass
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

-- Every floating panel shares this namespace, so these settings apply to all of them; the blur
-- region j2bar sends marks where each one is. `corner_radius` must match j2bar's panel radius.
glass.layer("noctalia-panel", {
  preset = "panel",
  mask_mode = "region",
  corner_radius = 12,
  rounding_power = 2.0,
  rim_light = 2.6,
  rim_shadow = 2.7,
  gleam_colors = {
    nix.palette.peach,
    nix.palette.yellow,
    nix.palette.teal,
    nix.palette.lavender,
    nix.palette.mauve,
    nix.palette.pink,
  },
  gleam_strength = 1.0,
  gleam_width = 1.2,
  gleam_length = 0.6,
  gleam_duration = 1.2,
  gleam_delay = 0.1,
  gleam_rest = 0.3,
})

-- `corner_radius` must match the radius of j2bar's on-screen display and of its polkit prompt.
for _, namespace in ipairs({ "j2bar-osd", "j2bar-polkit" }) do
  glass.layer(namespace, {
    preset = "panel",
    mask_mode = "region",
    corner_radius = 12,
    rounding_power = 2.0,
    rim_light = 2.6,
    rim_shadow = 2.7,
  })
end

-- Each of j2bar's banners is its own piece of the blur region, so each gets its own glass. Banners
-- come and go too often for a gleam. `corner_radius` must match j2bar's banner radius.
glass.layer("j2bar-notification", {
  preset = "panel",
  mask_mode = "region",
  corner_radius = 20,
  rounding_power = 2.0,
  rim_light = 2.6,
  rim_shadow = 2.7,
})
