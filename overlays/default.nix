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

  unstable =
    final: _prev:
    let
      unstable = importNixpkgs inputs.nixpkgs-unstable final;
    in
    {
      unstable = unstable // {
        # TODO: drop this override and the manifest once nixpkgs-unstable reaches 2.1.280.
        claude-code = unstable.claude-code.override {
          manifest = final.lib.importJSON ./claude-code/manifest.zst.json;
        };
        # Hyprland scales floating panels in and out like windows, so Noctalia's own clip reveal
        # would run on top of it, and a bar widget's panel centers under the widget like a macOS
        # menu bar item.
        noctalia =
          assert final.lib.assertMsg (unstable.noctalia.version == "5.0.1") (
            "The Noctalia patches were written for 5.0.1, not ${unstable.noctalia.version}; "
            + "re-check them against the new source and update this assertion."
          );
          unstable.noctalia.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/noctalia/floating-panels-no-reveal.patch
              ./patches/noctalia/panel-anchor-widget-center.patch
            ];
          });
      };
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
