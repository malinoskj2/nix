{
  # USB drive: boot doesn't wait for it, and an absent drive leaves a root-owned
  # empty mount point that nothing can write models into.
  fileSystems."/mnt/ext-ssd" = {
    device = "/dev/disk/by-label/ext-ssd";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
      "x-systemd.device-timeout=5s"
    ];
  };
}
