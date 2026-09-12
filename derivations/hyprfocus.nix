# hyprfocus from hyprland-plugins, newer than nixpkgs' v0.55.0 tag.
# Pinned to the last hyprfocus commit before the plugins moved to Hyprland 0.56 APIs;
# bump alongside Hyprland (see hyprpm.toml in the repo for version pins).
{
  lib,
  cmake,
  fetchFromGitHub,
  hyprland,
  hyprlandPlugins,
}:

# The patches hook and poke Hyprland internals, so any Hyprland change needs them re-checked.
assert lib.assertMsg (hyprland.version == "0.55.4")
  "hyprfocus patches were written against Hyprland 0.55.4 but got ${hyprland.version}; re-check derivations/hyprfocus-*.patch before bumping the nixpkgs-hyprland pin.";

hyprlandPlugins.mkHyprlandPlugin rec {
  pluginName = "hyprfocus";
  version = "0.55.4-unstable-2026-06-14";

  src = fetchFromGitHub {
    owner = "hyprwm";
    repo = "hyprland-plugins";
    rev = "1f90c674d51a1ef83c725cd6d02280b4c969fdf7";
    hash = "sha256-Kt56e6Bq2sfqN8yq1RHsS6z+8QKCZelmhaeQQRtZyqU=";
  };
  sourceRoot = "${src.name}/hyprfocus";

  patches = [
    # Adds plugin:hyprfocus:class so the animation can be limited to specific windows,
    # and skips newly mapped windows.
    ./hyprfocus-class-filter.patch
    # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
    ./hyprfocus-combined-modes.patch
    # Makes shrink a render-time scale instead of resizing the client.
    ./hyprfocus-render-shrink.patch
  ];

  nativeBuildInputs = [ cmake ];

  meta = {
    homepage = "https://github.com/hyprwm/hyprland-plugins";
    description = "Hyprland focus animation plugin";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
