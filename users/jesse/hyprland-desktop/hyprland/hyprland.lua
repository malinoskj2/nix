-- `nix` is prepended at build time.
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

local FILE_CHOOSER_APP = "xdg-desktop-portal-gtk"
local FILE_CHOOSER_CLASS = "^(" .. FILE_CHOOSER_APP .. ")$"

local function noctalia_msg(command)
  return hl.dsp.exec_cmd(nix.noctalia .. " msg " .. command)
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
  input = {
    accel_profile = "flat",
    follow_mouse = 0,
    repeat_delay = 260,
    repeat_rate = 24,
  },
})

-- agent-sandbox's nested Hyprland loads the same file, so both draw surfaces alike.
require("look")

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
      -- hyprfocus's shrink_percentage.
      dip = 0.99,
    },
  },
})

-- A critically damped spring spends its last stretch creeping through the final pixels, and the
-- chooser's text shimmers while it's resampled at nearly its own size. `land` is damped just under
-- critical, so it reaches the chooser's size at a small speed, and hyprsheet stops it the moment it
-- gets there.
hl.curve("land", { type = "spring", stiffness = 625, dampening = 42.5, mass = 1 })
hl.animation({ leaf = "hyprsheetIn", enabled = true, speed = 7, spring = "land" })
hl.animation({ leaf = "hyprsheetOut", enabled = true, speed = 7, spring = "land" })

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

-- Q and V act on the focused window; Q quits its app too, and floating resizes it, as its tiled size
-- rarely fits.
hl.bind(MAIN_MOD .. " + Q", actions.close_and_quit({ [FILE_CHOOSER_APP] = true }))
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
hl.bind(MAIN_MOD .. " + ALT + H", hl.dsp.window.resize({ x = -10, y = 0, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + L", hl.dsp.window.resize({ x = 10, y = 0, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + K", hl.dsp.window.resize({ x = 0, y = -10, relative = true }))
hl.bind(MAIN_MOD .. " + ALT + J", hl.dsp.window.resize({ x = 0, y = 10, relative = true }))

-- Y and O cycle back and forth through the main monitor's numbered workspaces.
hl.bind(MAIN_MOD .. " + Y", actions.focus_workspace(-1))
hl.bind(MAIN_MOD .. " + O", actions.focus_workspace(1))
hl.bind(MAIN_MOD .. " + SHIFT + Y", actions.move_to_workspace(-1))
hl.bind(MAIN_MOD .. " + SHIFT + O", actions.move_to_workspace(1))

-- Only Alacritty and mpv have a bar to grab, so the mouse moves and resizes windows with the
-- modifier held.
hl.bind(MAIN_MOD .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(MAIN_MOD .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Windows tile under the master layout, so their maximize requests would only fight it.
hl.window_rule({
  name = "suppress-maximize-events",
  match = { class = ".*" },
  suppress_event = "maximize",
})

-- Alacritty dims while unfocused.
hl.window_rule({
  match = { class = "^(Alacritty)$" },
  immediate = true,
  opacity = "1.0 override 0.85 override",
})

hl.window_rule({
  name = "hide-hyprbars-outside-alacritty-and-mpv",
  match = { class = "negative:^(Alacritty|mpv)$" },
  ["hyprbars:no_bar"] = true,
})

-- `immediate` allows tearing where input latency matters.
hl.window_rule({ match = { class = "^(firefox)$" }, immediate = true })
hl.window_rule({ match = { class = "^(jetbrains-datagrip)$" }, immediate = true })

-- Dialog-like windows float rather than disturb the tiled layout.
hl.window_rule({ match = { class = "^(dev\\.noctalia\\.Noctalia)$" }, float = true, size = { 1080, 920 } })
hl.window_rule({ match = { class = "^(mpv)$" }, float = true, center = true, keep_aspect_ratio = true })
-- The file chooser's GTK theme draws its own frame and shadow; Hyprland caps rounding at 20.
hl.window_rule({
  match = { class = FILE_CHOOSER_CLASS },
  float = true,
  rounding = 20,
  no_shadow = true,
})
