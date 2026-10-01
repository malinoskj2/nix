{
  config,
  inputs,
  lib,
  pkgs,
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
  webMimeTypes = [
    "application/x-extension-htm"
    "application/x-extension-html"
    "application/x-extension-shtml"
    "application/x-extension-xht"
    "application/x-extension-xhtml"
    "application/xhtml+xml"
    "text/html"
    "x-scheme-handler/chrome"
    "x-scheme-handler/http"
    "x-scheme-handler/https"
  ];
  focusedFirefox = pkgs.writeShellApplication {
    name = "firefox-focused";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      # An existing Firefox accepts the URL through its remote instance and may live on another
      # workspace. Prefer its most recently used window on the main monitor's numbered workspaces,
      # falling back to the side monitor when that is the only Firefox; if Firefox is starting,
      # wait for it to map.
      preferred_firefox() {
        ${lib.getExe' pkgs.hyprland "hyprctl"} clients -j 2>/dev/null \
          | ${lib.getExe pkgs.jq} -r \
            '[.[] | select(.class == "firefox")] as $firefox
             | [$firefox[] | select(.workspace.id > 0)] as $main
             | (if $main | length > 0 then $main else $firefox end)
             | min_by(.focusHistoryID)
             | .address // empty' 2>/dev/null || true
      }

      focus_firefox() {
        ${lib.getExe' pkgs.hyprland "hyprctl"} dispatch \
          "hl.dsp.focus({ window = \"address:$1\" })" >/dev/null
      }

      address="$(preferred_firefox)"
      if [[ -n "$address" ]]; then
        # Firefox sends a remote URL to its active window. Give the main-monitor window focus before
        # sending it so the new tab opens there, rather than in a more recently used side window.
        focus_firefox "$address"
        sleep 0.05
      fi

      ${lib.getExe cfg.package} --name firefox "$@" &

      if [[ -n "$address" || -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        exit
      fi

      for _ in {1..100}; do
        address="$(preferred_firefox)"

        if [[ -n "$address" ]]; then
          focus_firefox "$address"
          exit
        fi

        sleep 0.05
      done
    '';
  };
  locked = value: {
    Status = "locked";
    Value = value;
  };
  rgba =
    color: percent: "rgba(${lib.concatMapStringsSep ", " toString (rgb color)}, ${opacity percent})";
in
{
  home.file."${cfg.profilesPath}/${cfg.profiles.default.path}/chrome/wavefox".source =
    "${inputs.wavefox}/chrome";

  home.sessionVariables.BROWSER = lib.getExe focusedFirefox;

  xdg = {
    desktopEntries.firefox-focused = {
      name = "Firefox Web Link";
      icon = "firefox";
      exec = "${lib.getExe focusedFirefox} %U";
      mimeType = webMimeTypes;
      noDisplay = true;
    };
    mimeApps.defaultApplications = lib.genAttrs webMimeTypes (_: "firefox-focused.desktop");
  };

  programs.firefox = {
    enable = true;
    configPath = "${config.xdg.configHome}/mozilla/firefox";
    policies = {
      ExtensionSettings."FirefoxColor@mozilla.com" = {
        install_url = "https://addons.mozilla.org/firefox/downloads/latest/firefox-color/latest.xpi";
        installation_mode = "force_installed";
      };
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

        # Pages get prefers-color-scheme: light while the chrome stays dark.
        "layout.css.prefers-color-scheme.content-override" = 1;

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
