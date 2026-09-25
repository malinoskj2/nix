-- `nix` is prepended by users/jesse/hyprland-desktop/hyprland/default.nix.
local actions = require("actions")(nix)

local MAIN_MOD = "SUPER"

local BROWSER = "firefox"
local CHROME = "google-chrome-stable"
local DB_CLIENT = "datagrip"
local EDITOR = "zeditor"
local TERMINAL = "alacritty"

-- Chrome's Vulkan WebGPU backend needs X11, so this profile runs under XWayland.
local CHROME_WEBGPU = table.concat({
  CHROME,
  "--class=chrome-webgpu",
  "--user-data-dir=$HOME/.cache/chrome-webgpu",
  "--ozone-platform=x11",
  "--enable-unsafe-webgpu",
  "--enable-features=Vulkan",
  "--ignore-gpu-blocklist",
  "--disable-gpu-sandbox",
}, " ")

-- These grays stay outside the palette because Catppuccin's neutrals carry a blue tint.
local HYPRBARS_TEXT = "rgb(d7dae0)"
local INACTIVE_BORDER = "rgba(595959aa)"
local SHADOW = "rgba(00000059)"

local FILE_CHOOSER_CLASS = "^(xdg-desktop-portal-gtk)$"

-- These Noctalia layer namespaces omit the `noctalia-` prefix, which `noctalia_layers` adds.
local GLASS_LAYERS = { "bar-.+" }
local TRANSLUCENT_LAYERS = { "dock", "osd", "window-switcher" }

-- ("rrggbb", "aa") -> "rgba(rrggbbaa)"
local function rgba(color, alpha)
  return "rgba(" .. color .. alpha .. ")"
end

local function noctalia_msg(command)
  return hl.dsp.exec_cmd(nix.noctalia .. " msg " .. command)
end

local function noctalia_layers(...)
  local names = {}
  for _, group in ipairs({ ... }) do
    table.move(group, 1, #group, #names + 1, names)
  end
  return "^noctalia-(" .. table.concat(names, "|") .. ")$"
end

-- The side monitor stands portrait on the left, so the main monitor starts at its rotated width.
hl.monitor({
  output = nix.monitors.side,
  mode = "1920x1080@144",
  position = "0x0",
  scale = 1,
  transform = 1,
})

hl.monitor({
  output = nix.monitors.main,
  mode = "1920x1080@360",
  position = "1080x0",
  scale = 1,
})

-- The side monitor gets a named workspace of its own, so it never takes a numbered one.
hl.workspace_rule({
  workspace = "name:side",
  monitor = nix.monitors.side,
  default = true,
  persistent = true,
  layout_opts = { orientation = "top" },
})

for id = nix.workspaces.first, nix.workspaces.last do
  hl.workspace_rule({
    workspace = tostring(id),
    monitor = nix.monitors.main,
    default = id == nix.workspaces.first,
    persistent = true,
  })
end

hl.config({
  cursor = {
    enable_hyprcursor = false,
  },
  decoration = {
    -- Blur is strong and vibrant because Noctalia's glass surfaces rely on what shows through them.
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
    border_size = 2,
    col = {
      active_border = {
        angle = 150,
        colors = {
          rgba(nix.palette.peach, nix.alpha.active_border),
          rgba(nix.palette.sky, nix.alpha.active_border),
        },
      },
      inactive_border = INACTIVE_BORDER,
    },
    layout = "master",
    resize_on_border = true,
  },
  input = {
    accel_profile = "flat",
    follow_mouse = 0,
    repeat_delay = 260,
    repeat_rate = 24,
  },
  misc = {
    disable_hyprland_logo = true,
    force_default_wallpaper = 0,
  },
  render = {
    expand_undersized_textures = false,
  },
})

-- Noctalia draws glass, so its layers need blur; `ignore_alpha` keeps it off transparent margins.
hl.layer_rule({
  match = { namespace = noctalia_layers(GLASS_LAYERS, TRANSLUCENT_LAYERS) },
  blur = true,
  blur_popups = true,
  no_anim = true,
})

hl.layer_rule({ match = { namespace = noctalia_layers(TRANSLUCENT_LAYERS) }, ignore_alpha = 0.5 })
hl.layer_rule({ match = { namespace = noctalia_layers(GLASS_LAYERS) }, ignore_alpha = 0.02 })
hl.layer_rule({ match = { namespace = noctalia_layers({ "bar-.+" }) }, xray = true })

-- Floating panels scale in and out like windows; attached panels grow out of the bar through
-- Noctalia's own reveal instead.
hl.layer_rule({ match = { namespace = noctalia_layers({ "panel" }) }, animation = "popin 80%" })
hl.layer_rule({ match = { namespace = noctalia_layers({ "attached-panel" }) }, no_anim = true })

-- One layer holds every notification banner, so each slides in and out through Noctalia instead.
hl.layer_rule({ match = { namespace = noctalia_layers({ "notification" }) }, no_anim = true })

hl.layer_rule({
  match = { namespace = "^noctalia-desktop-widget-" .. nix.control_button_id .. ":.+$" },
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
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8, bezier = "default" })
-- `fadeOut` is off because the `windowsOut` popin already animates closing windows.
hl.animation({ leaf = "fadeOut", enabled = false })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 3, bezier = "linear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, spring = "sway" })

-- Most windows are borderless, so hyprfocus dips the focused one to make focus changes visible.
hl.plugin.load(nix.hyprfocus)

hl.config({
  plugin = {
    hyprfocus = {
      keyboard_focus_animation = "shrink",
      mouse_focus_animation = "shrink",
      shrink_percentage = 0.99,
    },
  },
})

hl.curve("hyprfocusDip", { type = "bezier", points = { { 0.25, 1 }, { 0.5, 1 } } })
hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.5, bezier = "hyprfocusDip" })
hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 4, bezier = "hyprfocusDip" })

-- Alacritty has no title bar of its own, so hyprbars gives it a thin one to grab and double-click.
hl.plugin.load(nix.hyprbars)

hl.config({
  plugin = {
    hyprbars = {
      bar_blur = false,
      bar_color = rgba(nix.palette.crust, nix.alpha.chrome),
      bar_height = 12,
      bar_part_of_window = true,
      bar_precedence_over_border = true,
      bar_text_align = "center",
      bar_text_font = "SF Pro Display",
      bar_text_size = 15,
      bar_text_weight = 600,
      bar_title_enabled = false,
      col = { text = HYPRBARS_TEXT },
      -- Under a Lua config, `hyprctl dispatch` takes an `hl.dsp` expression.
      on_double_click = nix.hyprctl .. [[ dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
    },
  },
})

-- hyprglass draws Noctalia's panels as refractive glass in the compositor, the only place that can
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
-- region Noctalia sends marks where each one is. `corner_radius` must match Noctalia's panel radius.
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

-- Each notification banner is its own piece of the blur region, so each gets its own glass. Banners
-- come and go too often for a gleam. `corner_radius` must match Noctalia's banner radius.
glass.layer("noctalia-notification", {
  preset = "panel",
  mask_mode = "region",
  corner_radius = 20,
  rounding_power = 2.0,
  rim_light = 2.6,
  rim_shadow = 2.7,
})

-- Attached panels flare into the bar, so their glass follows the region alone, without a rim.
glass.layer("noctalia-attached-panel", { preset = "panel", mask_mode = "region" })

-- While a file chooser is open, hyprsheet draws the app that opened it scaled into the chooser and
-- faded out, so a tiled app keeps its layout and never re-lays out for a size it only appears at.
hl.plugin.load(nix.hyprsheet)

hl.config({
  plugin = {
    hyprsheet = {
      class = FILE_CHOOSER_CLASS,
      -- The chooser takes this share of the app that opened it, but stays usable over small ones.
      parent_share = 0.75,
      min_size = { 700, 450 },
    },
  },
})

hl.animation({ leaf = "hyprsheetIn", enabled = true, speed = 7, spring = "snap" })
hl.animation({ leaf = "hyprsheetOut", enabled = true, speed = 7, spring = "glide" })

-- Noctalia reads its mpvpaper wallpaper assignments only at startup, so they're randomized first.
hl.on("hyprland.start", function()
  hl.exec_cmd(nix.wallpaper_randomize .. "; exec " .. nix.noctalia)
end)

-- Letters are mnemonic for the application; SHIFT picks a variant.
hl.bind(MAIN_MOD .. " + Return", hl.dsp.exec_cmd(TERMINAL))
hl.bind(MAIN_MOD .. " + F", hl.dsp.exec_cmd(BROWSER))
hl.bind(MAIN_MOD .. " + C", hl.dsp.exec_cmd(CHROME))
hl.bind(MAIN_MOD .. " + SHIFT + C", hl.dsp.exec_cmd(CHROME_WEBGPU))
hl.bind(MAIN_MOD .. " + D", hl.dsp.exec_cmd(DB_CLIENT))
hl.bind(MAIN_MOD .. " + E", hl.dsp.exec_cmd(EDITOR))

-- Q and V act on the focused window; floating resizes it too, as its tiled size rarely fits.
hl.bind(MAIN_MOD .. " + Q", hl.dsp.window.close())
hl.bind(MAIN_MOD .. " + V", actions.toggle_floating())

-- Noctalia owns the shell, so these binds go through its IPC.
hl.bind(MAIN_MOD .. " + P", noctalia_msg("screenshot-region"))
hl.bind(MAIN_MOD .. " + Escape", noctalia_msg("session lock"))
hl.bind(MAIN_MOD .. " + Space", noctalia_msg("panel-toggle launcher"))
hl.bind(MAIN_MOD .. " + S", noctalia_msg("panel-toggle control-center"))
hl.bind(MAIN_MOD .. " + comma", noctalia_msg("settings-toggle"))
hl.bind("XF86AudioRaiseVolume", noctalia_msg("volume-up"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", noctalia_msg("volume-down"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", noctalia_msg("volume-mute"), { locked = true })

-- H, J, K and L follow vim's directions to move focus, swap with SHIFT and resize with ALT.
hl.bind(MAIN_MOD .. " + H", hl.dsp.focus({ direction = "left" }))
hl.bind(MAIN_MOD .. " + L", hl.dsp.focus({ direction = "right" }))
hl.bind(MAIN_MOD .. " + K", hl.dsp.focus({ direction = "up" }))
hl.bind(MAIN_MOD .. " + J", hl.dsp.focus({ direction = "down" }))
hl.bind(MAIN_MOD .. " + SHIFT + H", hl.dsp.window.swap({ direction = "left" }))
hl.bind(MAIN_MOD .. " + SHIFT + L", hl.dsp.window.swap({ direction = "right" }))
hl.bind(MAIN_MOD .. " + SHIFT + K", hl.dsp.window.swap({ direction = "up" }))
hl.bind(MAIN_MOD .. " + SHIFT + J", hl.dsp.window.swap({ direction = "down" }))
hl.bind(MAIN_MOD .. " + ALT + H", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + L", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + K", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + J", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))

-- Y and O cycle back and forth through the main monitor's numbered workspaces; see actions.lua.
hl.bind(MAIN_MOD .. " + Y", actions.focus_workspace(-1))
hl.bind(MAIN_MOD .. " + O", actions.focus_workspace(1))
hl.bind(MAIN_MOD .. " + SHIFT + Y", actions.move_to_workspace(-1))
hl.bind(MAIN_MOD .. " + SHIFT + O", actions.move_to_workspace(1))

-- Only Alacritty has a bar to grab, so the mouse moves and resizes windows with the modifier held.
hl.bind(MAIN_MOD .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(MAIN_MOD .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Windows tile under the master layout, so their maximize requests would only fight it.
hl.window_rule({
  name = "suppress-maximize-events",
  match = { class = ".*" },
  suppress_event = "maximize",
})

-- Alacritty is the one window that keeps a hyprbars bar, and it dims while unfocused.
hl.window_rule({
  match = { class = "^(Alacritty)$" },
  immediate = true,
  opacity = "1.0 override 0.85 override",
  border_size = 0,
})

hl.window_rule({
  name = "hide-hyprbars-outside-alacritty",
  match = { class = "negative:^(Alacritty)$" },
  ["hyprbars:no_bar"] = true,
})

-- These applications draw their own chrome, so borders only add noise; `immediate` allows tearing
-- where input latency matters.
hl.window_rule({ match = { class = "^(com\\.anthropic\\.Claude)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(dev\\.zed\\.Zed)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(firefox)$" }, immediate = true, border_size = 0 })
hl.window_rule({ match = { class = "^(jetbrains-datagrip)$" }, immediate = true, border_size = 0 })
hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, border_size = 0 })

-- Dialog-like windows float rather than disturb the tiled layout.
hl.window_rule({ match = { class = "^(dev\\.noctalia\\.Noctalia)$" }, float = true, size = { 1080, 920 } })
-- The file chooser's GTK theme draws its own frame and shadow; Hyprland caps rounding at 20.
hl.window_rule({
  match = { class = FILE_CHOOSER_CLASS },
  float = true,
  rounding = 20,
  border_size = 0,
  no_shadow = true,
})
