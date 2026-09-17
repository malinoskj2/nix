{ inputs }:

let
  # Another nixpkgs source instantiated for the same platform and config as pkgs.
  importAlongside =
    nixpkgs: pkgs:
    import nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (pkgs) config;
    };
in
{
  # Local packages from pkgs/, as pkgs.<name>.
  additions = final: _prev: import ../pkgs { pkgs = final; };

  unstable = final: _prev: {
    unstable = importAlongside inputs.nixpkgs-unstable final;
  };

  # Packages taken from exact nixpkgs revisions. See docs/updating.md before bumping either input.
  pins =
    final: _prev:
    let
      hyprlandPkgs = importAlongside inputs.nixpkgs-hyprland final;
      firefoxPkgs = importAlongside inputs.nixpkgs-firefox final;
      inherit (hyprlandPkgs) hyprland hyprlandPlugins;
    in
    {
      inherit hyprland;
      inherit (hyprlandPkgs) xdg-desktop-portal-hyprland;
      inherit (firefoxPkgs) firefox;

      hyprlandPlugins = hyprlandPlugins // {
        # The patches hook and poke Hyprland internals, so any Hyprland change needs them re-checked.
        hyprfocus =
          assert final.lib.assertMsg (hyprland.version == "0.56.2")
            "hyprfocus patches were written against Hyprland 0.56.2 but got ${hyprland.version}; re-check overlays/patches/hyprfocus/*.patch before bumping the nixpkgs-hyprland pin.";
          hyprlandPlugins.hyprfocus.overrideAttrs (old: {
            version = "${old.version}-patched";
            __intentionallyOverridingVersion = true;
            patches = (old.patches or [ ]) ++ [
              # Adds plugin:hyprfocus:class so the animation can be limited to specific windows,
              # and skips newly mapped windows.
              ./patches/hyprfocus/class-filter.patch
              # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
              ./patches/hyprfocus/combined-modes.patch
              # Makes shrink a render-time scale instead of resizing the client.
              ./patches/hyprfocus/render-shrink.patch
            ];

            meta = old.meta // {
              description = "Hyprland focus animation plugin with local class filter, combined modes, and render-only shrink";
            };
          });
      };
    };
}
