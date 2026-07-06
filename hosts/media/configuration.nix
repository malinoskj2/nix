{ ... }:

{
  imports = [
    ./hardware-configuration.nix
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
}
