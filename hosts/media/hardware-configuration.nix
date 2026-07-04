# PLACEHOLDER — replace on the real machine.
#
# On the target run:
#   nixos-generate-config --no-filesystems --root /mnt   (installer)
#   or  nixos-generate-config                             (already installed)
# and copy the generated hardware-configuration.nix over this file, or let
# nixos-anywhere/disko own the filesystem layout instead.
#
# The values below are only enough to let the flake evaluate. They are NOT
# correct for any real disk.
{ modulesPath, lib, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "nvme"
    "usbhid"
    "sd_mod"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  # Large data volume for media. Point at the real disk once provisioned.
  # fileSystems."/srv/media" = {
  #   device = "/dev/disk/by-label/media";
  #   fsType = "ext4";
  #   options = [ "noatime" ];
  # };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
