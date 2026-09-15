_:

{
  networking.hostName = "katana";

  # No declarative interfaces or wireless networks here on purpose. The
  # NixOS default (networking.useDHCP) already leases on every interface,
  # and wifi is joined imperatively with `wifi-connect` (hosts/katana/package.nix).
  networking.firewall.enable = true;
}
