{ config, pkgs, ... }:

{
  networking.hostName = "home";

  networking.interfaces.enp8s0.useDHCP = true;

  networking.firewall.enable = false;
}
