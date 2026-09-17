_:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./network.nix
    ./sound.nix
    ./wayland.nix
    ./font.nix
    ./package.nix
    ./program.nix
    ../../modules/nixos/base.nix
    ../../modules/nixos/desktop.nix
    ../../modules/nixos/wayland.nix
  ];

  system.stateVersion = "24.11";

  home-manager.users.jesse.imports = [ ../../users/jesse ];
}
