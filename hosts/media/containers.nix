{
  # media-stack's containers run as this user. It isn't in the docker group,
  # so a container escape as it can't drive the daemon.
  users = {
    users.media = {
      isSystemUser = true;
      uid = 2000;
      group = "media";
    };
    groups.media.gid = 2000;
  };

  virtualisation.docker = {
    autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
    daemon.settings = {
      live-restore = true;
      no-new-privileges = true;
      # Networks stay out of 192.168.0.0/16, which Caddy's lan_only trusts.
      default-address-pools = [
        {
          base = "172.16.0.0/12";
          size = 24;
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
    32400
  ];
}
