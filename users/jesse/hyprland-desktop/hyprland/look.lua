-- `nix` is prepended at build time.
-- Desktop glass, title bars, focus/chooser/recession effects, curves and animation
-- policy live in programs.j2bar.settings.effects. Keep session policy here.
hl.config({
  cursor = { enable_hyprcursor = false },
  general = {
    allow_tearing = true,
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

-- Declare on every reload; omitting an already loaded config plugin unloads it.
-- j2bar observes plugin readiness and applies the single typed visual snapshot.
hl.plugin.load(nix.j2barPlugin)
