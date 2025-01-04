# User
{ config, pkgs, ... }:

{
  users.users.jesse = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "network"
      "video"
      "docker"
      "audio"
      "disk"
      "networkmanager"
      "systemd-journal"
    ];
    shell = pkgs.zsh;
  };
}

