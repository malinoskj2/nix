# Hand-written: the Pi has no generated hardware-configuration.nix.
{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot.kernelModules = [ "iwlwifi" ];

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
