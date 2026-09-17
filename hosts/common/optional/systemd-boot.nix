# systemd-boot for UEFI hosts without Secure Boot.
{
  boot.loader = {
    efi.canTouchEfiVariables = true;
    systemd-boot.enable = true;
  };
}
