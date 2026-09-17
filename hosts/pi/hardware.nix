let
  mkDisk = label: fsType: {
    device = "/dev/disk/by-label/${label}";
    inherit fsType;
    options = [ "noatime" ];
  };
in
{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot.kernelModules = [ "iwlwifi" ];

  fileSystems = {
    "/" = mkDisk "pi-root" "ext4";
    "/boot" = mkDisk "pi-boot" "vfat";
    "/media" = mkDisk "media" "ext4";
  };
}
