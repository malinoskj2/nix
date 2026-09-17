# Machine administration: hardware, service, process and network tools.
{ pkgs, ... }:
{
  imports = [ ../htop.nix ];

  home.packages = with pkgs; [
    ata-devs
    battery
    find-service
    wifi-connect

    dig
    killall
  ];
}
