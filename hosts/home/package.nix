# Package
{ config, pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    docker-compose
    clang_13
    unzip
    usbutils
    pciutils
    lshw
    uutils-coreutils-noprefix
  ];
}
