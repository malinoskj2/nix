-- `nix` is prepended at build time.
hl.config({
  cursor = { enable_hyprcursor = false },
  general = {
    allow_tearing = true,
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

-- Declare on every reload; omitting an already loaded config plugin unloads it.
hl.plugin.load(nix.j2barPlugin)
