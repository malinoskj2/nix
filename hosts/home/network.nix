{ config, pkgs, ... }:

{
  networking.hostName = "home";

  # Noctalia's network integration talks to NetworkManager over D-Bus.
  # Let NetworkManager own the interfaces and create the wired DHCP profile.
  networking.networkmanager.enable = true;

  networking.firewall.enable = false;
}
