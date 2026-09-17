# Escalating bans for repeat offenders; private LAN ranges are never banned
# (the NixOS module always exempts loopback).
{
  services.fail2ban = {
    enable = true;
    maxretry = 4;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
      factor = "4";
    };
    ignoreIP = [
      "192.168.0.0/16"
      "10.0.0.0/8"
    ];
  };
}
