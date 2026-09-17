{ config, inputs, ... }:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager

    ../../home-manager.nix
  ];

  users.users.jesse.extraGroups = [
    "audio"
    "disk"
    "systemd-journal"
    "video"
  ];

  # Home Manager's zsh runs compinit itself.
  programs.zsh.enableGlobalCompInit = false;

  home-manager.users.jesse = ../../../../users/jesse/profiles + "/${config.networking.hostName}.nix";
}
