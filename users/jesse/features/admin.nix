# Machine administration: hardware and network helpers.
{ pkgs, ... }:
{
  imports = [ ../htop.nix ];

  home.packages = with pkgs; [
    ata-devs
    battery
    find-service
    wifi-connect
    killall
    dig
  ];
}
