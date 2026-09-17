# jesse at a machine he sits at: hardware and journal groups, and his Home
# Manager profile from users/jesse/hosts/<hostName>.nix.
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

  home-manager.users.jesse = ../../../../users/jesse/hosts + "/${config.networking.hostName}.nix";
}
