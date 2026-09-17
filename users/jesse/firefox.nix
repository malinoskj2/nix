{
  config,
  inputs,
  lib,
  ...
}:

let
  cfg = config.programs.firefox;
  inherit (config.palette) mocha glass;
  rgba =
    color: percent:
    "rgba(${
      lib.concatMapStringsSep ", " toString (config.palette.rgb color)
    }, ${config.palette.opacity percent})";
in
{
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";

    policies = {
      ExtensionSettings."FirefoxColor@mozilla.com" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/firefox-color/latest.xpi";
        installation_mode = "force_installed";
      };

      # Locked by policy so Sync and experiments can't change them. The Preferences policy only
      # accepts allowlisted prefixes; other prefs go in the profile's user.js below.
      Preferences =
        lib.mapAttrs
          (_: Value: {
            inherit Value;
            Status = "locked";
          })
          {
            "media.hardware-video-decoding.force-enabled" = true;
            "gfx.content.skia-font-cache-size" = 20;
            "gfx.canvas.accelerated.cache-size" = 512;
            "browser.tabs.unloadOnLowMemory" = true;
          };

      # Hides sponsored shortcuts and stories only; ordinary ones stay.
      FirefoxHome = {
        SponsoredTopSites = false;
        SponsoredStories = false;
        Locked = true;
      };
    };

    profiles.default = {
      path = "oenjespe.default";
      settings = {
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        # Not an allowlisted policy prefix, so Firefox would reject it there.
        "image.mem.decode_bytes_at_a_time" = 32768;
        # GTK toplevel is opaque without an ARGB visual, so transparent chrome would render solid.
        "mozilla.widget.use-argb-visuals" = true;
        # WaveFox 0.6.x targets the Nova UI.
        "browser.nova.enabled" = true;
        "WaveFox.HorizontalTabs.AttachedTabs" = true;
      };
      # Transparent chrome lets Hyprland's window blur show through; page content stays opaque.
      # Transparency is declared first because, for !important rules, earlier layers win,
      # and WaveFox sets its backgrounds with !important in its own layers.
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

  # The wavefox input's release must match nixpkgs-firefox's major version.
  home.file."${cfg.profilesPath}/${cfg.profiles.default.path}/chrome/wavefox".source =
    "${inputs.wavefox}/chrome";

  catppuccin.firefox = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";
    force = true;
  };
}
