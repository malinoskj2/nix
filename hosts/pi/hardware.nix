# Hardware
{ boot, fileSystems, ... }:

{
  imports = [
    "${
      fetchTarball
      "https://github.com/NixOS/nixos-hardware/archive/936e4649098d6a5e0762058cb7687be1b2d90550.tar.gz"
    }/raspberry-pi/4"
  ];

  boot.tmp.useTmpfs = true;
  boot.kernelModules = [ "iwlwifi" ];
  boot.kernelParams = [ "cgroup_enable=memory" "swapaccount=1" ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/pi-root";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    "/boot" = {
      device = "/dev/disk/by-label/pi-boot";
      fsType = "vfat";
      options = [ "noatime" ];
    };
    "/media" = {
      device = "/dev/disk/by-label/media";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };
}
