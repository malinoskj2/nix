{ pkgs, ... }:

let
  stackDir = "/home/jesse/pi-media-stack";
  updateScript = pkgs.writeShellScript "docker-media-update" ''
    set -euo pipefail
    cd ${stackDir}
    ${pkgs.docker-compose}/bin/docker-compose pull
    ${pkgs.docker-compose}/bin/docker-compose up -d
  '';
in
{
  systemd.services.docker-media-update = {
    description = "Update media docker stack (compose pull + up -d)";
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = stackDir;
      Environment = "HOME=/root";
      ExecStart = updateScript;
    };
  };

  systemd.timers.docker-media-update = {
    description = "Weekly media docker stack update — 04:00 America/New_York";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      Persistent = true; # catch up on next boot if the box was off
      RandomizedDelaySec = "10m";
    };
  };
}
