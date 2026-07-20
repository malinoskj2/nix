# Package
{ config, pkgs, ... }: {
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

    # Needed by ~/env/script/sys/wifi_connect
    iw
    wpa_supplicant
  ];
}
