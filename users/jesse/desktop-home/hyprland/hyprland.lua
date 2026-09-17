-- `nix` is the table of Nix-provided values that hyprland/default.nix has Home Manager prepend.
local actions = require("actions")(nix.monitors.main, nix.workspaces.first, nix.workspaces.last)

local terminal = "alacritty"
local browser = "firefox"
local dbclient = "datagrip"
local editor = "zeditor"
local chrome = "google-chrome-stable"
local main_mod = "SUPER"
-- Not Catppuccin colours.
local INACTIVE_BORDER = "rgba(595959aa)"
local HYPRBARS_TEXT = "rgb(d7dae0)"
local function noctalia_msg(command)
  return hl.dsp.exec_cmd(nix.noctalia .. " msg " .. command)
end
local chrome_webgpu = table.concat({
  chrome,
  "--class=chrome-webgpu",
  "--user-data-dir=$HOME/.cache/chrome-webgpu",
  "--ozone-platform=x11",
  "--enable-unsafe-webgpu",
  "--enable-features=Vulkan",
  "--ignore-gpu-blocklist",
  "--disable-gpu-sandbox",
}, " ")

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

hl.config({
  general = {
    border_size = 2,
    col = {
      active_border = {
        colors = {
          "rgba(" .. nix.palette.peach .. nix.alpha.active_border .. ")",
          "rgba(" .. nix.palette.sky .. nix.alpha.active_border .. ")",
        },
        angle = 150,
      },
      inactive_border = INACTIVE_BORDER,
    },
    resize_on_border = true,
    allow_tearing = true,
    layout = "master",
  },
  cursor = {
    enable_hyprcursor = false,
  },
  decoration = {
    rounding = 10,
    blur = {
      passes = 3,
      noise = 0.02,
      vibrancy = 0.2,
    },
    shadow = {
      range = 32,
      color = "rgba(00000059)",
    },
  },
  render = {
    expand_undersized_textures = false,
  },
  misc = {
    force_default_wallpaper = 0,
    disable_hyprland_logo = true,
  },
  input = {
    follow_mouse = 0,
    accel_profile = "flat",
    repeat_delay = 260,
    repeat_rate = 24,
  },
})

local GLASS_LAYERS = { "bar-.+", "panel", "attached-panel" }
local TRANSLUCENT_LAYERS = { "notification", "dock", "osd", "window-switcher" }

local function noctalia_layers(...)
  local names = {}
  for _, group in ipairs({ ... }) do
    table.move(group, 1, #group, #names + 1, names)
  end
  return "^noctalia-(" .. table.concat(names, "|") .. ")$"
end

hl.layer_rule({
  match = { namespace = noctalia_layers(GLASS_LAYERS, TRANSLUCENT_LAYERS) },
  blur = true,
  blur_popups = true,
  no_anim = true,
})
hl.layer_rule({
  match = { namespace = noctalia_layers(TRANSLUCENT_LAYERS) },
  ignore_alpha = 0.5,
})
hl.layer_rule({
  match = { namespace = noctalia_layers(GLASS_LAYERS) },
  ignore_alpha = 0.02,
})
hl.layer_rule({
  match = { namespace = noctalia_layers({ "bar-.+" }) },
  xray = true,
})
hl.layer_rule({
  match = { namespace = "^noctalia-desktop-widget-" .. nix.control_button .. ":.+$" },
  blur = true,
  ignore_alpha = 0.05,
})

hl.curve("overshoot", {
  type = "bezier",
  points = { { 0.05, 0.9 }, { 0.1, 1.05 } },
})
hl.animation({ leaf = "windows", enabled = true, speed = 7, bezier = "overshoot" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 7, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "fadeOut", enabled = false })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 3, bezier = "linear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "default" })

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
hl.curve("hyprfocusDip", {
  type = "bezier",
  points = { { 0.25, 1 }, { 0.5, 1 } },
})
hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.5, bezier = "hyprfocusDip" })
hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 4, bezier = "hyprfocusDip" })

hl.plugin.load(nix.hyprbars)
hl.config({
  plugin = {
    hyprbars = {
      bar_color = "rgba(" .. nix.palette.crust .. nix.alpha.chrome .. ")",
      bar_blur = false,
      bar_height = 12,
      col = { text = HYPRBARS_TEXT },
      bar_title_enabled = false,
      bar_text_size = 15,
      bar_text_weight = 600,
      bar_text_font = "SF Pro Display",
      bar_text_align = "center",
      bar_part_of_window = true,
      bar_precedence_over_border = true,
      -- `hyprctl dispatch` takes hl.dsp syntax under a Lua config.
      on_double_click = nix.hyprctl .. [[ dispatch 'hl.dsp.window.fullscreen({ mode = "maximized" })']],
    },
  },
})

hl.on("hyprland.start", function()
  -- Keep randomization ahead of Noctalia: its mpvpaper plugin reads the
  -- assignment file once during startup.
  hl.exec_cmd(nix.wallpaper_randomize .. "; exec " .. nix.noctalia)
end)

hl.bind(main_mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(main_mod .. " + F", hl.dsp.exec_cmd(browser))
hl.bind(main_mod .. " + C", hl.dsp.exec_cmd(chrome))
hl.bind(main_mod .. " + SHIFT + C", hl.dsp.exec_cmd(chrome_webgpu))
hl.bind(main_mod .. " + D", hl.dsp.exec_cmd(dbclient))
hl.bind(main_mod .. " + E", hl.dsp.exec_cmd(editor))
hl.bind(main_mod .. " + P", noctalia_msg("screenshot-region"))
hl.bind(main_mod .. " + Escape", noctalia_msg("session lock"))
hl.bind(main_mod .. " + Q", hl.dsp.window.close())
hl.bind(main_mod .. " + V", actions.toggle_floating)

hl.bind(main_mod .. " + Space", noctalia_msg("panel-toggle launcher"))
hl.bind(main_mod .. " + S", noctalia_msg("panel-toggle control-center"))
hl.bind(main_mod .. " + comma", noctalia_msg("settings-toggle"))
hl.bind("XF86AudioRaiseVolume", noctalia_msg("volume-up"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", noctalia_msg("volume-down"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", noctalia_msg("volume-mute"), { locked = true })

hl.bind(main_mod .. " + H", hl.dsp.focus({ direction = "left" }))
hl.bind(main_mod .. " + L", hl.dsp.focus({ direction = "right" }))
hl.bind(main_mod .. " + K", hl.dsp.focus({ direction = "up" }))
hl.bind(main_mod .. " + J", hl.dsp.focus({ direction = "down" }))

hl.bind(main_mod .. " + SHIFT + H", hl.dsp.window.swap({ direction = "left" }))
hl.bind(main_mod .. " + SHIFT + L", hl.dsp.window.swap({ direction = "right" }))
hl.bind(main_mod .. " + SHIFT + K", hl.dsp.window.swap({ direction = "up" }))
hl.bind(main_mod .. " + SHIFT + J", hl.dsp.window.swap({ direction = "down" }))

hl.bind(main_mod .. " + ALT + H", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(main_mod .. " + ALT + L", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(main_mod .. " + ALT + K", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))
hl.bind(main_mod .. " + ALT + J", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))

hl.bind(main_mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(main_mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

hl.bind(main_mod .. " + O", function()
  actions.focus_workspace(1)
end)
hl.bind(main_mod .. " + Y", function()
  actions.focus_workspace(-1)
end)
hl.bind(main_mod .. " + SHIFT + O", function()
  actions.move_to_workspace(1)
end)
hl.bind(main_mod .. " + SHIFT + Y", function()
  actions.move_to_workspace(-1)
end)

hl.window_rule({
  name = "suppress-maximize-events",
  match = { class = ".*" },
  suppress_event = "maximize",
})
hl.window_rule({
  match = { class = "^(Alacritty)$" },
  immediate = true,
  opacity = "1.0 override 0.85 override",
  border_size = 0,
})
hl.window_rule({ match = { class = "^(firefox)$" }, immediate = true, border_size = 0 })
hl.window_rule({ match = { class = "^(dev\\.zed\\.Zed)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, border_size = 0 })
hl.window_rule({ match = { class = "^(jetbrains-datagrip)$" }, immediate = true, border_size = 0 })
hl.window_rule({ match = { class = "^(xdg-desktop-portal-gtk)$" }, float = true })
hl.window_rule({ match = { class = "^(dev\\.noctalia\\.Noctalia)$" }, float = true, size = { 1080, 920 } })
hl.window_rule({
  name = "hide-hyprbars-outside-alacritty",
  match = { class = "negative:^(Alacritty)$" },
  ["hyprbars:no_bar"] = true,
})

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
