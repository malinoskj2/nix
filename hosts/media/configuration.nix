{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./storage.nix
    ./network.nix
    ./user.nix
    ./ssh.nix
    ./docker.nix
    ./docker-autoupdate.nix
    ./nvidia.nix
    ./hardening.nix
    ./package.nix
    ./misc.nix
  ];

  system.stateVersion = "25.11";
}
