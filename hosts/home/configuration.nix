{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./misc.nix
    ./network.nix
    ./wayland.nix
    ./package.nix
    ./user.nix
    ./virtualisation.nix
    ./program.nix
    ./secure-boot.nix
    ./scheduler.nix
    ../../modules/nixos/audio.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/fonts.nix
    ../../modules/nixos/wayland.nix
    inputs.nix-index-database.nixosModules.nix-index
  ];

  system.stateVersion = "25.11";

  programs.nix-index-database.comma.enable = true;

  home-manager.users.jesse.imports = [
    ../../users/jesse
    ../../users/jesse/desktop-home
  ];
}
