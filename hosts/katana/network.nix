{ config, pkgs, ... }:

{
  networking.hostName = "katana";

  # No declarative interfaces or wireless networks here on purpose. The
  # NixOS default (networking.useDHCP) already leases on every interface,
  # and wifi is joined imperatively with ~/env/script/sys/wifi_connect.
  networking.firewall.enable = true;
}
