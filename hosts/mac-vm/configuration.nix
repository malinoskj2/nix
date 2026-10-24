{ inputs, ... }:
{
  imports = [
    inputs.nix-index-database.nixosModules.nix-index

    ../common/global.nix
    ../common/optional/docker.nix
    ../common/optional/fonts.nix
    ../common/optional/hyprland.nix
    ../common/optional/j2bar.nix
    ../common/optional/nh.nix
    ../common/optional/pipewire.nix
    ../common/optional/systemd-boot.nix
    ../common/optional/workstation.nix
    ../common/users/jesse
    ../common/users/jesse/interactive.nix

    ./hardware-configuration.nix
  ];

  networking = {
    hostName = "mac-vm";

    # j2bar's network source talks to NetworkManager over D-Bus.
    networkmanager.enable = true;
  };

  virtualisation.vmware.guest.enable = true;

  zramSwap.enable = true;

  programs.nix-index-database.comma.enable = true;

  system.stateVersion = "26.05";
}
