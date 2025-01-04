{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware.nix
    ./network.nix
    ./package.nix
    ./virtualization.nix
    ./user.nix
    ./systemd.nix
    ./ssh.nix
    ./misc.nix
    ./samba.nix
  ];
}
