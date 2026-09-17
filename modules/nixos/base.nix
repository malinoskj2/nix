# Shared baseline for the home and katana desktop hosts.
{ pkgs, ... }:

{
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    substituters = [ "https://nix-community.cachix.org" ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  programs = {
    ssh.startAgent = true;
    zsh.enable = true;
    zsh.enableGlobalCompInit = false;
    nix-ld = {
      enable = true;
      libraries = [ pkgs.libcap ];
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    unzip
    usbutils
    pciutils
    lshw
    uutils-coreutils-noprefix
  ];
}
