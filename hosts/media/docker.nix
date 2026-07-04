# Docker — the whole media stack runs in containers.
{ pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;
    # nixpkgs 25.11 default `docker` (28.x) is flagged unmaintained; pin the
    # maintained line so an exposed host isn't running an EOL engine.
    package = pkgs.docker_29;
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--all" ];
    };
    # Containers survive reboots without depending on the Docker socket at boot.
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

  # Put your compose project(s) here, e.g. /srv/media/docker-compose.yml, and
  # bring the stack up with `docker compose up -d`. Bind app ports to 127.0.0.1
  # and let the reverse-proxy container be the only thing on 80/443.
  systemd.tmpfiles.rules = [
    "d /srv/media 0750 jesse docker - -"
  ];

  environment.systemPackages = with pkgs; [ docker-compose ];
}
