# The Docker compose media stack: daemon settings for its containers and a
# weekly image update. The stack itself lives outside this repo (its directory
# name predates the stack's move from pi).
{ pkgs, ... }:

let
  composeDir = "/home/jesse/pi-media-stack";
in
{
  virtualisation.docker = {
    autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
    daemon.settings = {
      live-restore = true;
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
      };
      no-new-privileges = true;
    };
  };

  systemd.tmpfiles.rules = [ "d /srv/media 0750 jesse docker - -" ];

  systemd.services.docker-media-update = {
    description = "Update media docker stack (compose pull + up -d)";
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    path = [ pkgs.docker-compose ];
    # systemd gives root units no HOME; compose reads registry auth from ~/.docker.
    environment.HOME = "/root";
    script = ''
      docker-compose pull
      docker-compose up -d
    '';
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = composeDir;
    };
    startAt = "Sun *-*-* 04:00:00";
  };

  systemd.timers.docker-media-update = {
    description = "Weekly media docker stack update";
    timerConfig = {
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
