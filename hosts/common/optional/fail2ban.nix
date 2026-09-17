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

    # The order reaches jail.local, so this list stays unsorted.
    ignoreIP = [
      "192.168.0.0/16"
      "10.0.0.0/8"
    ];
  };
}
