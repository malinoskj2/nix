# Package
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    unzip
    usbutils
    pciutils
    lshw
    read-edid
    uutils-coreutils-noprefix
  ];
}
