# Package
{ config, pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    docker-compose
    unzip
    usbutils
    pciutils
    lshw
    uutils-coreutils-noprefix
  ];
}
