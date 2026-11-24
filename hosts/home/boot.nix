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

  # The ASM4242 xHCI times out entering runtime suspend and stays wedged until a
  # cold boot, taking the rear USB4 Type-C ports with it.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1b21", ATTR{device}=="0x2425|0x2426", ATTR{power/control}="on"
  '';

  hardware.cpu.amd.ryzen-smu.enable = true;

  environment.systemPackages = [ pkgs.sbctl ];
}
