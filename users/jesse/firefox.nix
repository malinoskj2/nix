{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (config.palette)
    glass
    mocha
    opacity
    rgb
    ;

  cfg = config.programs.firefox;

  locked = value: {
    Status = "locked";
    Value = value;
  };

  rgba =
    color: percent: "rgba(${lib.concatMapStringsSep ", " toString (rgb color)}, ${opacity percent})";
in
{
  # The wavefox input's release must match nixpkgs-firefox's major version; see docs/updating.md.
  home.file."${cfg.profilesPath}/${cfg.profiles.default.path}/chrome/wavefox".source =
    "${inputs.wavefox}/chrome";

  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";

    policies = {
      ExtensionSettings."FirefoxColor@mozilla.com" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/firefox-color/latest.xpi";
        installation_mode = "force_installed";
      };

      # Hides sponsored shortcuts and stories only; ordinary ones stay.
      FirefoxHome = {
        Locked = true;
        SponsoredStories = false;
        SponsoredTopSites = false;
      };

      # Locked by policy so Sync and experiments can't change them.
      Preferences = lib.mapAttrs (_: locked) {
        "browser.tabs.unloadOnLowMemory" = true;
        "gfx.canvas.accelerated.cache-size" = 512;
        "gfx.content.skia-font-cache-size" = 20;
        "media.hardware-video-decoding.force-enabled" = true;
      };
    };

    profiles.default = {
      path = "oenjespe.default";

      settings = {
        "WaveFox.HorizontalTabs.AttachedTabs" = true;
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

        # WaveFox 0.6.x targets the Nova UI.
        "browser.nova.enabled" = true;

        # Not an allowlisted prefix, so the Preferences policy would reject it.
        "image.mem.decode_bytes_at_a_time" = 32768;

        # GTK toplevel is opaque without an ARGB visual, so transparent chrome would render solid.
        "mozilla.widget.use-argb-visuals" = true;
      };

      # Transparent chrome lets Hyprland's window blur show through; page content stays
      # opaque. Transparency is declared first because earlier layers win for !important
      # rules, and WaveFox sets its backgrounds with !important in its own layers.
      userChrome = ''
        @layer Transparency, BasicPriority, HighPriority, VeryHighPriority;
        @import "wavefox/userChrome.css";

        @layer Transparency {
          :root {
            --toolbox-background-color: ${rgba mocha.crust glass.chrome} !important;
            --toolbox-background-color-inactive: ${rgba mocha.crust glass.chrome} !important;
            --toolbar-background-color: ${rgba mocha.base glass.chrome} !important;
            --toolbar-field-background-color: ${rgba mocha.mantle glass.layer} !important;
          }
          #main-window { background: transparent !important; }
        }
      '';
    };
  };

  catppuccin.firefox = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";
    force = true;
  };
}
