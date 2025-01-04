{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./misc.nix
    ./network.nix
    ./sound.nix
    ./x.nix
    ./wayland.nix
    ./font.nix
    ./package.nix
    ./user.nix
    ./virtualisation.nix
    ./program.nix
  ];

  system.stateVersion = "24.11";
}
