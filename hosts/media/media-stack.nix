{ pkgs, ... }:
let
  # The Compose project lives in its own checkout, outside this repository.
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
      no-new-privileges = true;
      log-opts = {
        max-file = "3";
        max-size = "10m";
      };
    };
  };

  systemd = {
    tmpfiles.rules = [ "d /srv/media 0750 jesse docker - -" ];

    services.docker-media-update = {
      description = "Update media docker stack (compose pull + up -d)";
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      after = [
        "docker.service"
        "network-online.target"
      ];
      path = [ pkgs.docker-compose ];

      # systemd gives root units no HOME, and Compose reads registry auth from ~/.docker.
      environment.HOME = "/root";
      script = ''
        docker-compose pull
        docker-compose up -d
      '';
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = composeDir;
      };
    };

    timers.docker-media-update = {
      description = "Weekly media docker stack update";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sun *-*-* 04:00:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
