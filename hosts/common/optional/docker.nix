{ pkgs, ... }:
{
  virtualisation.docker = {
    enable = true;
    # A switch that restarts dockerd would otherwise stop every container.
    daemon.settings.live-restore = true;
  };

  environment.systemPackages = [ pkgs.docker-compose ];
}
