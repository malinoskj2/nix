{
  # Mounted on first access, so boot never waits for the media host. A soft mount returns
  # errors instead of hanging programs if it goes away while mounted.
  fileSystems."/mnt/media3" = {
    device = "192.168.1.200:/mnt/media3";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "timeo=100"
      "retrans=2"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=10min"
      "x-systemd.mount-timeout=10s"
    ];
  };
}
