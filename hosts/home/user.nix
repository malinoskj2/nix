{
  imports = [ ../../modules/nixos/desktop.nix ];

  users.users.jesse.extraGroups = [ "docker" ];
}
