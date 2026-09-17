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
    lshw
    pciutils
    unzip
    usbutils
    wget

    # The noprefix build shadows GNU coreutils, so ls, cp and the rest run uutils.
    uutils-coreutils-noprefix
  ];
}
