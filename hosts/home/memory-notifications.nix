{ lib, pkgs, ... }:
let
  monitor = pkgs.writers.writePython3Bin "memory-notifications" {
    # Ruff formats this repository at 120 columns; retain the other checks.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./memory-notifications.py);
in
{
  # Jesse already belongs to systemd-journal. Watch the host journal, where
  # the kernel reports both global OOMs and container memory-limit kills.
  home-manager.users.jesse.systemd.user.services.memory-notifications = {
    Unit = {
      Description = "Desktop alerts for high RAM usage and OOM kills";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe monitor)
        "--journalctl"
        (lib.getExe' pkgs.systemd "journalctl")
        "--notify-send"
        (lib.getExe pkgs.libnotify)
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
