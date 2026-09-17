{ inputs, pkgs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4

    ../common/global.nix
    ../common/optional/docker.nix
    # Only nh's store cleanup applies here, since pi has no checkout at nh's flake path.
    ../common/optional/nh.nix
    ../common/optional/server-tools.nix

    ./hardware.nix
    ./cgroups.nix
    ./samba.nix
  ];

  networking = {
    hostName = "pi";
    interfaces.eth0.useDHCP = true;
    nameservers = [ "1.1.1.1" ];
  };

  boot.tmp.useTmpfs = true;

  # Overrides global.nix's default, leaving the clock on UTC.
  time.timeZone = null;

  users.users.pi = {
    isNormalUser = true;
    extraGroups = [
      "docker"
      "wheel"
    ];
  };

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    hdparm
    idle3tools
    nixfmt
    usbutils
  ];

  system.stateVersion = "24.11";
}
