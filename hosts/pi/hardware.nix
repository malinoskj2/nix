# Hardware
{ inputs, ... }:

{
  imports = [ inputs.nixos-hardware.nixosModules.raspberry-pi-4 ];

  nixpkgs.hostPlatform = "aarch64-linux";

  boot = {
    tmp.useTmpfs = true;
    kernelModules = [ "iwlwifi" ];
    kernelParams = [
      "cgroup_enable=memory"
      "swapaccount=1"
    ];
  };

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
