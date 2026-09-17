{ inputs }:
let
  # Imports another nixpkgs source with the platform and config of pkgs, so allowUnfree reaches it.
  importNixpkgs =
    nixpkgs: pkgs:
    import nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (pkgs) config;
    };
in
{
  # Adds the local packages from pkgs/ as pkgs.<name>.
  additions = final: _prev: import ../pkgs { pkgs = final; };

  # Exposes nixpkgs-unstable as pkgs.unstable.
  unstable = final: _prev: {
    unstable = importNixpkgs inputs.nixpkgs-unstable final;
  };

  # Takes packages from exact nixpkgs commits and patches hyprfocus; see docs/updating.md.
  pins =
    final: _prev:
    let
      inherit (final) lib;
      inherit (importNixpkgs inputs.nixpkgs-firefox final) firefox;

      inherit (importNixpkgs inputs.nixpkgs-hyprland final)
        hyprland
        hyprlandPlugins
        xdg-desktop-portal-hyprland
        ;

      supportedHyprlandVersions = [ "0.56.2" ];
    in
    {
      inherit firefox hyprland xdg-desktop-portal-hyprland;

      hyprlandPlugins = hyprlandPlugins // {
        # The patches hook Hyprland internals, so a clean apply to a new version proves nothing.
        hyprfocus =
          assert lib.assertMsg (lib.elem hyprland.version supportedHyprlandVersions) (
            "hyprfocus patches were written for Hyprland "
            + "${lib.concatStringsSep ", " supportedHyprlandVersions}, not ${hyprland.version}; "
            + "re-check them and update this assertion."
          );
          hyprlandPlugins.hyprfocus.overrideAttrs (old: {
            version = "${old.version}-patched";
            __intentionallyOverridingVersion = true;

            patches = (old.patches or [ ]) ++ [
              # Adds plugin:hyprfocus:class to animate only windows whose class matches, and
              # skips windows that are still opening.
              ./patches/hyprfocus/class-filter.patch
              # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
              ./patches/hyprfocus/combined-modes.patch
              # Makes shrink a render-time scale instead of resizing the client.
              ./patches/hyprfocus/render-shrink.patch
            ];

            meta = old.meta // {
              description = "${old.meta.description}, with local patches";
            };
          });
      };
    };
}
