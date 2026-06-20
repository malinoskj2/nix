# Misc
{ config, pkgs, ... }:

{
  time.timeZone = "US/Eastern";
  i18n.defaultLocale = "en_US.UTF-8";

  # 16 GiB swapfile on ext4 root; NixOS creates /swapfile on activation.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
    }
  ];

  nix = {
    extraOptions = "experimental-features = nix-command flakes";
    settings = {
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };
}
