-- Hyprland draws to its own headless output: the sway it nests in has no input devices, so its
-- window never receives the traffic that starts Aquamarine's Wayland output. It matches the
-- desktop's main monitor, since bars and panels lay out to the output's size.
hl.monitor({ output = "WAYLAND-1", disabled = true })
hl.monitor({ output = "NESTED-1", mode = "1920x1080@60", position = "0x0", scale = 1 })

hl.config({
  -- A headless output has no cursor plane, so the cursor lands in every screenshot; the desktop's
  -- never do. Hiding it once the pointer rests keeps screenshots of hovered states alike.
  cursor = {
    inactive_timeout = 0.1,
  },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_watchdog_warning = true,
    disable_xdg_env_checks = true,
  },
})

-- The launcher mounts the desktop's Hyprland config here, whose look.lua sets how Hyprland draws:
-- blur, layer rules, animations and plugins.
local HOST_CONFIG = "/run/host-hypr/?.lua"
if package.searchpath("look", HOST_CONFIG) then
  package.path = HOST_CONFIG .. ";" .. package.path
  require("look")
end

hl.on("hyprland.start", function()
  hl.exec_cmd("hyprctl output create headless NESTED-1")
end)
