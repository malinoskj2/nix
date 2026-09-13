{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./misc.nix
    ./network.nix
    ./openvpn.nix
    ./sound.nix
    ./x.nix
    ./wayland.nix
    ./hyprfocus.nix
    ./hyprbars.nix
    ./font.nix
    ./package.nix
    ./user.nix
    ./virtualisation.nix
    ./program.nix
    ./secure-boot.nix
    ./scheduler.nix
  ];

  system.stateVersion = "25.11";
}
