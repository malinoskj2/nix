{ config, pkgs, ... }:

{
  # Ensure cifs-utils available
  environment.systemPackages = with pkgs; [
    cifs-utils
  ];

  # Auto-mount samba share from pi
  # Non-blocking: automount + short timeouts prevent boot hang
  fileSystems."/mnt/pi" = {
    device = "//pi.j34/public";
    fsType = "cifs";
    options = [
      "x-systemd.automount"
      "x-systemd.idle-timeout=60"
      "x-systemd.device-timeout=5s"
      "x-systemd.mount-timeout=5s"
      "guest"
      "uid=1000"
      "gid=100"
      "dir_mode=0755"
      "file_mode=0644"
    ];
  };
}
