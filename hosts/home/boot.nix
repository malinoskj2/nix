{ pkgs, ... }:
{
  boot.loader = {
    efi.canTouchEfiVariables = true;
    limine = {
      enable = true;
      efiSupport = true;
      maxGenerations = 10;
      style.wallpapers = [
        pkgs.nixos-artwork.wallpapers.simple-dark-gray-bootloader.gnomeFilePath
      ];

      # secureBoot also enforces enrollConfig, validateChecksums and panicOnChecksumMismatch.
      secureBoot.enable = true;
    };
  };

  environment.systemPackages = [ pkgs.sbctl ];
}
