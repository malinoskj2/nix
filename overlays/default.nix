{ inputs }:

{
  # Packages taken from exact nixpkgs revisions. See CLAUDE.md before bumping either input.
  pins =
    final: prev:
    let
      system = prev.stdenv.hostPlatform.system;
    in
    {
      inherit (inputs.nixpkgs-hyprland.legacyPackages.${system})
        hyprland
        hyprlandPlugins
        xdg-desktop-portal-hyprland
        ;
      inherit (inputs.nixpkgs-firefox.legacyPackages.${system}) firefox;
    };

  # Every pkgs/<name>/package.nix becomes pkgs.<name>.
  additions =
    final: prev:
    prev.lib.packagesFromDirectoryRecursive {
      inherit (final) callPackage;
      directory = ../pkgs;
    };

  modifications = final: prev: {
    hyprlandPlugins = prev.hyprlandPlugins // {
      # The patches hook and poke Hyprland internals, so any Hyprland change needs them re-checked.
      hyprfocus =
        assert prev.lib.assertMsg (final.hyprland.version == "0.56.2")
          "hyprfocus patches were written against Hyprland 0.56.2 but got ${final.hyprland.version}; re-check patches/hyprfocus/*.patch before bumping the nixpkgs-hyprland pin.";
        prev.hyprlandPlugins.hyprfocus.overrideAttrs (old: {
          version = "${old.version}-patched";
          __intentionallyOverridingVersion = true;
          patches = [
            # Adds plugin:hyprfocus:class so the animation can be limited to specific windows,
            # and skips newly mapped windows.
            ../patches/hyprfocus/class-filter.patch
            # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
            ../patches/hyprfocus/combined-modes.patch
            # Makes shrink a render-time scale instead of resizing the client.
            ../patches/hyprfocus/render-shrink.patch
          ];

          meta = old.meta // {
            description = "Hyprland focus animation plugin with local class filter, combined modes, and render-only shrink";
          };
        });
    };
  };
}
