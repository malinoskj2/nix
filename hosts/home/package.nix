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
    libva-utils
    uutils-coreutils-noprefix
    hyprpaper
    waybar

    # Pulls in the full dotnet SDK, so keep it off the other hosts
    source2viewer-cli
  ];
}
