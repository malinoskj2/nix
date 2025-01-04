{ config, pkgs, secrets, ... }:

{
  networking.hostName = "home";

  networking.interfaces.enp4s0.useDHCP = true;

  networking.extraHosts = secrets.extraHosts;

  networking.firewall.enable = false;
}
