# Hyprbars at the commit which added configurable title font weight, after the
# Hyprland 0.55 API update and before the MonitorState/0.56 API migration.
{
  lib,
  cmake,
  hyprland,
  hyprlandPlugins,
  src,
}:

assert lib.assertMsg (hyprland.version == "0.55.4")
  "hyprbars is pinned for Hyprland 0.55.4 but got ${hyprland.version}; update the source pin alongside Hyprland.";

hyprlandPlugins.mkHyprlandPlugin rec {
  pluginName = "hyprbars";
  version = "0.55.4-unstable-2026-05-19";

  inherit src;

  nativeBuildInputs = [ cmake ];

  meta = {
    homepage = "https://github.com/hyprwm/hyprland-plugins";
    description = "Hyprland window title plugin";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
