# Patched hyprfocus based on the source packaged with this exact Hyprland set.
{
  lib,
  hyprland,
  hyprlandPlugins,
}:

# The patches hook and poke Hyprland internals, so any Hyprland change needs them re-checked.
assert lib.assertMsg (hyprland.version == "0.56.2")
  "hyprfocus patches were written against Hyprland 0.56.2 but got ${hyprland.version}; re-check derivations/hyprfocus-*.patch before bumping the nixpkgs-hyprland pin.";

hyprlandPlugins.hyprfocus.overrideAttrs (old: {
  version = "${old.version}-patched";
  __intentionallyOverridingVersion = true;
  patches = [
    # Adds plugin:hyprfocus:class so the animation can be limited to specific windows,
    # and skips newly mapped windows.
    ./hyprfocus-class-filter.patch
    # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
    ./hyprfocus-combined-modes.patch
    # Makes shrink a render-time scale instead of resizing the client.
    ./hyprfocus-render-shrink.patch
  ];

  meta = old.meta // {
    description = "Hyprland focus animation plugin with local class filter, combined modes, and render-only shrink";
  };
})
