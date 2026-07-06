{ pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    package = pkgs.docker_29;
    autoPrune = {
      enable = true;
      dates = "weekly";
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
      features.cdi = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /srv/media 0750 jesse docker - -"
  ];

  environment.systemPackages = with pkgs; [ docker-compose ];
}
