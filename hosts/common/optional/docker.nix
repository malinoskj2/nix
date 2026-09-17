# Docker engine and Compose, for hosts that run containers.
{ pkgs, ... }:
{
  virtualisation.docker.enable = true;

  environment.systemPackages = [ pkgs.docker-compose ];
}
