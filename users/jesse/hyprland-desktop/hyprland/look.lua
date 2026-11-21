-- `nix` is prepended at build time.

-- This gray stays outside the palette because Catppuccin's neutrals carry a blue tint.
local SHADOW = "rgba(00000059)"

-- ("rrggbb", "aa") -> "rgba(rrggbbaa)"
local function rgba(color, alpha)
  return "rgba(" .. color .. alpha .. ")"
end

hl.config({
  cursor = { enable_hyprcursor = false },
  decoration = {
    -- Blur is strong and vibrant because glass surfaces rely on what shows through them.
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
    gaps_out = 18,
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

-- Tohru draws, blurs and animates its own surfaces, all on layers named `pleamar`. The launcher's
-- backdrop layer only tells the plugin's recession, below, when the launcher is open.
hl.layer_rule({ match = { namespace = "^(pleamar|tohru-launcher-backdrop)$" }, no_anim = true })

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

-- Declare on every reload; omitting an already loaded config plugin unloads it.
hl.plugin.load(nix.tohruPlugin)

-- Windows are borderless, so the plugin dips the focused one to make focus changes visible.
-- The file chooser dips through the plugin's sheet instead, which scales its frame rather than resizing
-- it, so its buttons don't lay out again at each size.
-- Alacritty and mpv have no title bar of their own, so the plugin gives them a thin one to grab
-- and double-click.
-- While a file chooser is open, the sheet draws the app that opened it scaled into the chooser and
-- faded out, so a tiled app keeps its layout and never re-lays out for a size it only appears at.
-- While the launcher is open, the recession leans the windows on its monitor back, shades them from
-- the top and blurs them, the way Liquid34 pushes the window behind a modal back.
hl.config({
  plugin = {
    hyprfocus = {
      keyboard_focus_animation = "shrink",
      mouse_focus_animation = "shrink",
      shrink_percentage = 0.99,
      class = "^(?!xdg-desktop-portal-gtk$).*$",
    },
    hyprbars = {
      bar_blur = false,
      bar_color = rgba(nix.palette.crust, nix.alpha.chrome),
      bar_height = 12,
      bar_part_of_window = true,
      bar_precedence_over_border = true,
      bar_title_enabled = false,
      -- The plugin toggles maximize itself.
      on_double_click = "tohru:maximize",
    },
    hyprsheet = {
      class = "^(xdg-desktop-portal-gtk)$",
      -- The chooser takes this share of the app that opened it, but stays usable over small ones.
      parent_share = 0.75,
      min_size = { 700, 450 },
      -- The focus dip's shrink_percentage.
      dip = 0.99,
    },
    hyprrecede = {
      namespace = "^tohru-launcher-backdrop$",
      angle = 16,
      scale = 0.86,
      perspective = 1400,
      shade = 0.62,
      blur = 1,
    },
  },
})

-- Compositor rules use RE2, so the whitelist is a negative match.
hl.window_rule({
  name = "hyprbars-only-alacritty-and-mpv",
  match = { class = "negative:^(Alacritty|mpv)$" },
  ["hyprbars:no_bar"] = true,
})

hl.curve("hyprfocusDip", { type = "bezier", points = { { 0.25, 1 }, { 0.5, 1 } } })

-- A critically damped spring spends its last stretch creeping through the final pixels, and the
-- chooser's text shimmers while it's resampled at nearly its own size. `land` is damped just under
-- critical, so it reaches the chooser's size at a small speed, and the sheet stops it the moment it
-- gets there.
hl.curve("land", { type = "spring", stiffness = 625, dampening = 42.5, mass = 1 })

-- Liquid34's transitions: the tilt takes 620 ms on its `--ease-settle`, the shade 500 ms on CSS's
-- `ease`. The blur finishes in 240 ms, during the launcher reveal, without a spring's settling
-- tail after the launcher is already fully visible.
hl.curve("settle", { type = "bezier", points = { { 0.3, 1.25 }, { 0.4, 1 } } })
hl.curve("ease", { type = "bezier", points = { { 0.25, 0.1 }, { 0.25, 1 } } })

local function plugin_animations()
  hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.5, bezier = "hyprfocusDip" })
  hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 4, bezier = "hyprfocusDip" })
  hl.animation({ leaf = "hyprsheetIn", enabled = true, speed = 7, spring = "land" })
  hl.animation({ leaf = "hyprsheetOut", enabled = true, speed = 7, spring = "land" })
  hl.animation({ leaf = "hyprrecedeTilt", enabled = true, speed = 6.2, bezier = "settle" })
  hl.animation({ leaf = "hyprrecedeShade", enabled = true, speed = 5, bezier = "ease" })
  hl.animation({ leaf = "hyprrecedeBlur", enabled = true, speed = 2.4, bezier = "ease" })
end

-- At startup the plugin loads only after this file has run, and an unknown animation leaf is an
-- error that would end the configuration here. Its leaves are set once Hyprland has started.
if not pcall(plugin_animations) then
  hl.on("hyprland.start", function()
    hl.timer(function()
      pcall(plugin_animations)
    end, { timeout = 1, type = "oneshot" })
  end)
end
