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
        # TODO: drop this override once nixpkgs-unstable reaches 0.157.1. Older clients aren't
        # offered the GPT-6 models.
        codex = unstable.codex.overrideAttrs (old: rec {
          version = "0.157.1";
          src = final.fetchFromGitHub {
            owner = "openai";
            repo = "codex";
            tag = "rust-v${version}";
            hash = "sha256-HuNL5VGd2LenhbCdcz0i8b6lRw3sicwXytyfXgCgy88=";
          };
          cargoDeps = final.rustPlatform.fetchCargoVendor {
            inherit src;
            inherit (old) sourceRoot;
            hash = "sha256-Mp4chq9QuQB19FrOZBhmUtPrDoEpZZna79+MZs9rGUo=";
          };
          patches = (old.patches or [ ]) ++ [ ./patches/codex/no-daemon_auto_start.patch ];
          postPatch = old.postPatch + ''
            sed -i '1i#![recursion_limit = "256"]' chatgpt/src/lib.rs
          '';
        });
        # Hyprland scales floating panels in and out like windows, so Noctalia's own clip reveal
        # would run on top of it, a bar widget's panel centers under the widget like a macOS
        # menu bar item, a plugin panel can set its own padding and resize to fit its content
        # like a menu, and plugin sliders take their own colors and can drop the thumb for
        # Apple's thin track. Notification toasts take the layout of macOS 27's banners and
        # slide in and out across the screen edge. A desktop widget's panel opens below the bar
        # with its left edge under the widget, like the Apple menu, and plugin rows, boxes and
        # images take a right click. A bar widget can drop its hover tooltip.
        noctalia =
          assert final.lib.assertMsg (unstable.noctalia.version == "5.0.1") (
            "The Noctalia patches were written for 5.0.1, not ${unstable.noctalia.version}; "
            + "re-check them against the new source and update this assertion."
          );
          unstable.noctalia.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./patches/noctalia/floating-panels-no-reveal.patch
              ./patches/noctalia/panel-anchor-widget-center.patch
              ./patches/noctalia/plugin-panel-layout.patch
              ./patches/noctalia/plugin-slider-style.patch
              ./patches/noctalia/notification-banners.patch
              ./patches/noctalia/desktop-widget-panel.patch
              ./patches/noctalia/widget-show-tooltip.patch
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
      # The patches hook Hyprland internals, so a clean apply to a new version proves nothing.
      patchPlugin =
        name: patches:
        assert lib.assertMsg (lib.elem hyprland.version supportedHyprlandVersions) (
          "${name} patches were written for Hyprland "
          + "${lib.concatStringsSep ", " supportedHyprlandVersions}, not ${hyprland.version}; "
          + "re-check them and update this assertion."
        );
        hyprlandPlugins.${name}.overrideAttrs (old: {
          version = "${old.version}-patched";
          __intentionallyOverridingVersion = true;
          patches = (old.patches or [ ]) ++ patches;
          meta = old.meta // {
            description = "${old.meta.description}, with local patches";
          };
        });
    in
    {
      inherit firefox hyprland xdg-desktop-portal-hyprland;
      hyprlandPlugins = hyprlandPlugins // {
        hyprbars = patchPlugin "hyprbars" [
          ./patches/hyprbars/transformed-pass.patch
          ./patches/hyprbars/unload-listeners.patch
        ];
        hyprfocus = patchPlugin "hyprfocus" [
          ./patches/hyprfocus/class-filter.patch
          ./patches/hyprfocus/combined-modes.patch
          ./patches/hyprfocus/render-shrink.patch
        ];
      };
    };
}
