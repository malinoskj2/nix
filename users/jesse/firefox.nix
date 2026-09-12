{
  config,
  inputs,
  ...
}:

{
  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    policies.ExtensionSettings."FirefoxColor@mozilla.com" = {
      install_url = "https://addons.mozilla.org/firefox/downloads/latest/firefox-color/latest.xpi";
      installation_mode = "force_installed";
    };
    # Firefox did not reliably import newly generated user.js values for this
    # existing profile. Apply these through the Preferences policy instead so
    # Sync, experiments, and Firefox Home cannot overwrite the Nix config.
    policies.Preferences = {
      "media.hardware-video-decoding.force-enabled" = {
        Value = true;
        Status = "locked";
      };
      "gfx.content.skia-font-cache-size" = {
        Value = 20;
        Status = "locked";
      };
      "gfx.canvas.accelerated.cache-size" = {
        Value = 512;
        Status = "locked";
      };
      "image.mem.decode_bytes_at_a_time" = {
        Value = 32768;
        Status = "locked";
      };
      "browser.tabs.unloadOnLowMemory" = {
        Value = true;
        Status = "locked";
      };
      # Keep sponsored shortcuts and sponsored stories off Firefox Home while
      # retaining ordinary shortcuts and recommendations.
      "browser.newtabpage.activity-stream.showSponsoredTopSites" = {
        Value = false;
        Status = "locked";
      };
      "browser.newtabpage.activity-stream.showSponsored" = {
        Value = false;
        Status = "locked";
      };
      "browser.newtabpage.activity-stream.showSponsoredCheckboxes" = {
        Value = false;
        Status = "locked";
      };
    };
    profiles.default = {
      id = 0;
      isDefault = true;
      path = "oenjespe.default";
      settings = {
        "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
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
            --toolbox-background-color: rgba(17, 17, 27, 0.55) !important;
            --toolbox-background-color-inactive: rgba(17, 17, 27, 0.55) !important;
            --toolbar-background-color: rgba(30, 30, 46, 0.55) !important;
            --toolbar-field-background-color: rgba(24, 24, 37, 0.6) !important;
          }
          #main-window { background: transparent !important; }
        }
      '';
    };
  };

  xdg.configFile."mozilla/firefox/oenjespe.default/chrome/wavefox".source =
    "${inputs.wavefox}/chrome";

  catppuccin.firefox = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";
    force = true;
  };
}
