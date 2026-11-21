{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  palette = config.palette.mocha;
  rgb = hex: "rgb(${hex})";
  hyprctl = lib.getExe' osConfig.programs.hyprland.package "hyprctl";
  # Under a Lua config, `hyprctl dispatch` takes an `hl.dsp` expression.
  dpms = action: "${hyprctl} dispatch 'hl.dsp.dpms({ action = \"${action}\" })'";
  pidof = lib.getExe' pkgs.procps "pidof";
  hyprlock = lib.getExe config.programs.hyprlock.package;

  # hyprlock leaves logind's LockedHint alone, and wallpaper-autopause reads it. The hint stays set
  # when hyprlock dies without unlocking, since Hyprland then keeps the session locked.
  lock = pkgs.writeShellApplication {
    name = "session-lock";
    runtimeInputs = [
      pkgs.jq
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      pidof hyprlock >/dev/null && exit 0

      session_id="''${XDG_SESSION_ID:-$(loginctl show-user "$USER" --property=Display --value)}"
      session_path="$(
        busctl --system --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
          org.freedesktop.login1.Manager GetSession s "$session_id" | jq -r '.data[0]'
      )"
      hint() {
        busctl --system call org.freedesktop.login1 "$session_path" \
          org.freedesktop.login1.Session SetLockedHint b "$1" || true
      }

      hint true
      ${hyprlock} && hint false
    '';
  };

  # Tohru's locker where Tohru runs; hyprlock on hosts without it (mac-vm).
  tohru = config.programs.tohru.enable;
  tohruLock = config.programs.tohru.lock.command;

  # Runs only while the session is locked, so the unlocked session keeps its own, longer timeouts.
  whileLocked =
    command:
    if tohru then "${tohruLock} --running && ${command}" else "${pidof} hyprlock >/dev/null && ${command}";
in
{
  programs.hyprlock = {
    enable = !tohru;
    # The NixOS module installs it with its PAM service.
    package = osConfig.programs.hyprlock.package;
    settings = {
      general = {
        hide_cursor = true;
        ignore_empty_input = true;
      };
      background = [
        {
          monitor = "";
          path = "screenshot";
          blur_passes = 3;
          blur_size = 8;
          brightness = 0.7;
        }
      ];
      label = [
        {
          monitor = config.desktop.monitors.main.output;
          text = ''cmd[update:1000] date +"%-I:%M"'';
          color = rgb palette.text;
          font_family = "SF Pro Display";
          font_size = 96;
          position = "0, 260";
          halign = "center";
          valign = "center";
        }
        {
          monitor = config.desktop.monitors.main.output;
          text = ''cmd[update:60000] date +"%A, %B %-d"'';
          color = rgb palette.subtext1;
          font_family = "SF Pro Display";
          font_size = 22;
          position = "0, 170";
          halign = "center";
          valign = "center";
        }
        {
          monitor = config.desktop.monitors.main.output;
          text = "$USER";
          color = rgb palette.text;
          font_family = "SF Pro Text";
          font_size = 16;
          position = "0, -60";
          halign = "center";
          valign = "center";
        }
      ];
      input-field = [
        {
          monitor = config.desktop.monitors.main.output;
          size = "280, 44";
          outline_thickness = 0;
          rounding = -1;
          inner_color = "rgba(${palette.surface0}b3)";
          font_color = rgb palette.text;
          check_color = rgb palette.lavender;
          fail_color = rgb palette.red;
          capslock_color = rgb palette.peach;
          placeholder_text = "Password";
          fail_text = "$FAIL";
          fade_on_empty = false;
          dots_center = true;
          position = "0, -120";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  # j2bar's idle behaviors: lock after 30 minutes, screens off a minute into a lock, and suspend
  # after 2 hours, or 90 minutes into a lock. Video players and systemd-inhibit still hold it off.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        # tohru-lock sets logind's LockedHint itself, and asking again while locked does nothing.
        lock_cmd = if tohru then tohruLock else lib.getExe lock;
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = dpms "on";
        # Suspend waits for the lock surface, so the session never wakes unlocked.
        inhibit_sleep = 3;
      };
      listener = [
        {
          timeout = 60;
          on-timeout = whileLocked (dpms "off");
          on-resume = dpms "on";
        }
        {
          timeout = 1800;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 1860;
          on-timeout = dpms "off";
          on-resume = dpms "on";
        }
        {
          timeout = 5400;
          on-timeout = whileLocked "systemctl suspend";
        }
        {
          timeout = 7200;
          on-timeout = "systemctl suspend";
        }
      ];
    };
  };

  home.packages = lib.optional (!tohru) lock;
}
