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
  additions =
    final: _prev:
    import ../pkgs {
      pkgs = final;
    };

  unstable = final: _prev: {
    unstable = importNixpkgs inputs.nixpkgs-unstable final;
  };

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
              ./patches/hyprfocus/class-filter.patch
              ./patches/hyprfocus/combined-modes.patch
              ./patches/hyprfocus/render-shrink.patch
            ];
            meta = old.meta // {
              description = "${old.meta.description}, with local patches";
            };
          });
      };
    };
}
