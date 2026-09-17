_:

{
  imports = [
    ./hardware.nix
    ./network.nix
    ./package.nix
    ./virtualisation.nix
    ./user.nix
    ./systemd.nix
    ./ssh.nix
    ./samba.nix
  ];

  system.stateVersion = "24.11";
}
