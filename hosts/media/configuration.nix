{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./network.nix
    ./user.nix
    ./ssh.nix
    ./docker.nix
    ./nvidia.nix
    ./hardening.nix
    ./package.nix
    ./misc.nix
  ];
}
