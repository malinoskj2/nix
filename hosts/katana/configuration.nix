{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./misc.nix
    ./network.nix
    ./sound.nix
    ./wayland.nix
    ./font.nix
    ./package.nix
    ./user.nix
    ./program.nix
  ];

  system.stateVersion = "24.11";

  home-manager.users.jesse = import ../../users/jesse;
}
