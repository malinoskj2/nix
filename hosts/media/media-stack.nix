{ pkgs, ... }:
let
  # The Compose project lives in its own checkout, outside this repository.
  composeDir = "/home/jesse/pi-media-stack";
in
{
  # The containers run as this user instead of jesse. It isn't in the docker
  # group, so a container escape as it can't drive the daemon.
  users = {
    users.media = {
      isSystemUser = true;
      uid = 2000;
      group = "media";
    };
    groups.media.gid = 2000;
  };

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

  # Docker confines every container with its docker-default profile once
  # AppArmor is on, and loads that profile with apparmor_parser.
  security.apparmor.enable = true;

  systemd = {
    tmpfiles.rules = [ "d /srv/media 0750 jesse docker - -" ];

    services.docker.path = [ pkgs.apparmor-parser ];

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

      # One image that fails to pull mustn't hold back the rest, but it still
      # fails the unit so it shows up in systemctl --failed.
      script = ''
        failed=0
        for service in $(docker-compose config --services); do
          docker-compose pull "$service" || failed=1
        done
        docker-compose up -d
        exit "$failed"
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
