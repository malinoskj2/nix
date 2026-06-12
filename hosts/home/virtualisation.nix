# virtualisation
{ config, pkgs, ... }:

{
  virtualisation.docker.enable = true;
  virtualisation.docker.package = pkgs.docker_29;
}
