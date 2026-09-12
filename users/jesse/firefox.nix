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
