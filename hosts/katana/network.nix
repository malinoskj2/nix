{ config, pkgs, secrets, ... }:

{
  networking.hostName = "katana";

  networking.wireless = {
    enable = true;
    networks.MALINOSKY_5GHZ.psk = secrets.wifiPsk.home;
  };

  networking.interfaces.wlp3s0.useDHCP = true;

  networking.firewall.enable = true;
}
