{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./misc.nix
    ./network.nix
    ./sound.nix
    ./wayland.nix
    ./font.nix
    ./package.nix
    ./user.nix
    ./virtualisation.nix
    ./program.nix
    ./secure-boot.nix
    ./scheduler.nix
    inputs.nix-index-database.nixosModules.nix-index
  ];

  system.stateVersion = "25.11";

  programs.nix-index-database.comma.enable = true;

  home-manager.users.jesse.imports = [
    ../../users/jesse
    ../../users/jesse/desktop-home
  ];
}
