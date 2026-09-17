{ pkgs, ... }:
{
  imports = [ ../htop.nix ];

  programs.btop = {
    enable = true;
    settings.vim_keys = true;
  };

  home.packages = with pkgs; [
    ata-devs
    battery
    find-service
    wifi-connect

    dig
    killall
  ];
}
