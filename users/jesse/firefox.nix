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

        # Performance tuning for this host (Wayland, NVIDIA, 32 GiB RAM).
        # Firefox 137+ requires this override for video decoding through
        # nvidia-vaapi-driver; the remaining cache sizes are conservative
        # Betterfox defaults that trade a little RAM for less repeated work.
        "media.hardware-video-decoding.force-enabled" = true;
        "gfx.content.skia-font-cache-size" = 20;
        "gfx.canvas.accelerated.cache-size" = 512;
        "image.mem.decode_bytes_at_a_time" = 32768;
        # Avoid swapping or an OOM by discarding least-recently-used tabs only
        # when Linux reports low memory. Pinned/media/WebRTC tabs are
        # deprioritized, and unloaded tabs remain visible and reload on demand.
        "browser.tabs.unloadOnLowMemory" = true;

        # Keep Firefox Home free of shortcuts and recommended stories.
        "browser.newtabpage.activity-stream.feeds.topsites" = false;
        "browser.newtabpage.activity-stream.feeds.section.topstories" = false;
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
