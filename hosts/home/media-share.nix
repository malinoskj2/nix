{
  # Mounted on first access, so boot never waits for the media host.
  fileSystems."/mnt/media3" = {
    device = "//192.168.1.200/media3";
    fsType = "cifs";
    options = [
      "credentials=/secret/media-smb.credentials"
      "uid=1000"
      "gid=100"
      "vers=3.1.1"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=10min"
      "x-systemd.mount-timeout=10s"
    ];
  };
}
