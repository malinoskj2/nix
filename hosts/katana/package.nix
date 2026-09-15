# Package
{ pkgs, ... }:
let
  wifiConnect = pkgs.writeShellApplication {
    name = "wifi-connect";
    runtimeInputs = with pkgs; [
      iw
      wpa_supplicant
      dhcpcd
      iproute2
      procps
      util-linux
      gawk
    ];
    text = builtins.readFile ./scripts/wifi_connect.sh;
  };

  battery = pkgs.writeShellApplication {
    name = "battery";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scripts/battery.sh;
  };
in
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

    wifiConnect
    battery
  ];
}
