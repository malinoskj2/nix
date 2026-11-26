{ config, pkgs, ... }:
{
  systemd.user.services.target-sweep = {
    Unit.Description = "Remove Cargo target directories of idle Orca worktrees";
    Service = {
      Type = "oneshot";
      Environment = "ORCA_CLI_COMMAND=${config.home.profileDirectory}/bin/orca-ide";
      ExecStart = "${pkgs.target-sweep}/bin/target-sweep";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.target-sweep = {
    Unit.Description = "Weekly sweep of idle worktrees' Cargo targets";
    Timer = {
      OnCalendar = "Sun 04:30";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
