# Limine with Secure Boot. sbctl signs only Limine's EFI binary; Limine then
# refuses any kernel or initrd whose checksum doesn't match the one recorded at
# build time. Windows lives on another SSD, picked from the firmware boot menu.
#
# One-time setup, before enabling Secure Boot in firmware:
#   1. Put Secure Boot into Setup Mode (clear the enrolled keys).
#   2. sudo sbctl create-keys
#   3. sudo sbctl enroll-keys -m -f   # -m keeps Microsoft's CAs so Windows still boots
#   4. nh os switch, then check with `sudo sbctl verify`
#   5. Enable Secure Boot in firmware.
{ pkgs, ... }:
{
  boot.loader = {
    efi.canTouchEfiVariables = true;

    limine = {
      enable = true;
      efiSupport = true;
      # Also enforces enrollConfig, validateChecksums and panicOnChecksumMismatch.
      secureBoot.enable = true;
      maxGenerations = 10;
      style.wallpapers = [
        pkgs.nixos-artwork.wallpapers.simple-dark-gray-bootloader.gnomeFilePath
      ];
    };
  };

  environment.systemPackages = [ pkgs.sbctl ];
}
