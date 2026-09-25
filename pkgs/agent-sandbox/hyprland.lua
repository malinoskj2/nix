-- Hyprland draws to its own headless output: the sway it nests in has no input devices, so its
-- window never receives the traffic that starts Aquamarine's Wayland output.
hl.monitor({ output = "WAYLAND-1", disabled = true })
hl.monitor({ output = "NESTED-1", mode = "1280x800@60", position = "0x0", scale = 1 })

hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_watchdog_warning = true,
    disable_xdg_env_checks = true,
  },
})

hl.on("hyprland.start", function()
  hl.exec_cmd("hyprctl output create headless NESTED-1")
end)
