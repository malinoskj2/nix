# fail2ban for internet-facing hosts, with bans that grow for repeat offenders.
{
  services.fail2ban = {
    enable = true;
    bantime = "1h";
    maxretry = 4;

    bantime-increment = {
      enable = true;
      factor = "4";
      maxtime = "48h";
    };

    # Private LAN ranges are never banned; the NixOS module always exempts loopback.
    # The order reaches jail.local, so this list stays unsorted.
    ignoreIP = [
      "192.168.0.0/16"
      "10.0.0.0/8"
    ];
  };
}
