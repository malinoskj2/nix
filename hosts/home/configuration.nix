# home: Ryzen 9 9950X3D desktop with an NVIDIA GPU, running Hyprland and the
# Noctalia shell.
{ inputs, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./nvidia.nix
    ./scheduler.nix

    ../common/global.nix
    ../common/users/jesse
    ../common/users/jesse/workstation.nix
    ../common/optional/docker.nix
    ../common/optional/fonts.nix
    ../common/optional/hyprland.nix
    ../common/optional/nh.nix
    ../common/optional/pipewire.nix
    ../common/optional/workstation.nix

    ./programs.nix
    inputs.nix-index-database.nixosModules.nix-index
  ];

  networking = {
    hostName = "home";

    # Noctalia's network integration talks to NetworkManager over D-Bus.
    # Let NetworkManager own the interfaces and create the wired DHCP profile.
    networkmanager.enable = true;

    firewall.enable = false;
  };

  # 16 GiB swapfile on ext4 root; NixOS creates /swapfile on activation.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
    }
  ];

  programs.nix-index-database.comma.enable = true;

  environment.systemPackages = with pkgs; [
    libva-utils

    # Pulls in the full dotnet SDK, so keep it off the other hosts
    source2viewer-cli
  ];

  system.stateVersion = "25.11";
}
