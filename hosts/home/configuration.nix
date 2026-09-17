# home: Ryzen 9 9950X3D desktop with an NVIDIA GPU, Hyprland workstation.
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.nix-index-database.nixosModules.nix-index

    ../common/global.nix
    ../common/optional/docker.nix
    ../common/optional/fonts.nix
    ../common/optional/hyprland.nix
    ../common/optional/nh.nix
    ../common/optional/pipewire.nix
    ../common/optional/workstation.nix
    ../common/users/jesse
    ../common/users/jesse/interactive.nix

    ./hardware-configuration.nix
    ./boot.nix
    ./gaming.nix
    ./nvidia.nix
    ./obs.nix
    ./scheduler.nix
  ];

  networking = {
    hostName = "home";
    firewall.enable = false;

    # Noctalia's network integration talks to NetworkManager over D-Bus, so
    # NetworkManager owns the interfaces and creates the wired DHCP profile.
    networkmanager.enable = true;
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
    }
  ];

  programs.nix-index-database.comma.enable = true;

  environment.systemPackages = with pkgs; [
    libva-utils

    # Pulls in the full .NET SDK, so only this host installs it.
    source2viewer-cli
  ];

  system.stateVersion = "25.11";
}
