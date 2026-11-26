{ pkgs, ... }:
{
  imports = [
    ../btop.nix
    ../htop.nix
  ];

  home.packages = with pkgs; [
    ata-devs
    battery
    find-service
    media-web
    wifi-connect

    dig
    killall
    smartmontools
  ];
}
