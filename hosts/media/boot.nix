_:

{
  # UEFI bootloader (moved out of hardware-configuration.nix, which has no
  # separate boot module of its own generation).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
