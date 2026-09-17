# Development workstation baseline: binary cache, nix-ld, ssh-agent, basic tools.
{ pkgs, ... }:
{
  nix.settings = {
    substituters = [ "https://nix-community.cachix.org" ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  programs = {
    ssh.startAgent = true;
    nix-ld = {
      enable = true;
      libraries = [ pkgs.libcap ];
    };
  };

  environment.systemPackages = with pkgs; [
    wget
    unzip
    usbutils
    pciutils
    lshw
    uutils-coreutils-noprefix
  ];
}
