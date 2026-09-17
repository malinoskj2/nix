# pi: Raspberry Pi 4 (aarch64) sharing a media disk over Samba, plus Docker.
{ inputs, pkgs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    ./hardware.nix

    ../common/global.nix
    ../common/optional/docker.nix
    ../common/optional/server-tools.nix
    # nh's flake path is jesse's checkout, which pi doesn't have; kept for now.
    ../common/optional/nh.nix

    ./cgroups.nix
    ./samba.nix
  ];

  networking = {
    hostName = "pi";
    interfaces.eth0.useDHCP = true;
    nameservers = [ "1.1.1.1" ];
  };

  services.openssh.enable = true;

  # No timezone yet (UTC); global.nix would otherwise set one.
  time.timeZone = null;

  boot.tmp.useTmpfs = true;

  users.users.pi = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  environment.systemPackages = with pkgs; [
    hdparm
    idle3tools
    nixfmt
    usbutils
  ];

  system.stateVersion = "24.11";
}
