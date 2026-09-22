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

  nix.settings = {
    max-jobs = 16;
    cores = 16;
  };

  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "20G";
    MemoryMax = "24G";
  };

  # agent-sandbox runs its container under this slice. MemoryHigh reclaims before
  # MemoryMax kills. A little swap is needed so reclaim can page out tmpfs; with
  # none, tmpfs over MemoryHigh stalls the whole slice instead of getting killed.
  systemd.slices.agent-sandbox.sliceConfig = {
    # The sandbox shares cores 4-7 with the desktop. If games or the browser
    # stutter on them, a low CPUWeight here hands those cores to the desktop on
    # contention without shrinking the cpuset.
    MemoryHigh = "20G";
    MemoryMax = "24G";
    MemorySwapMax = "4G";
  };

  programs.nix-index-database.comma.enable = true;

  environment.systemPackages = with pkgs; [
    agent-sandbox
    libva-utils

    # Pulls in the full .NET SDK, so only this host installs it.
    source2viewer-cli
  ];

  system.stateVersion = "25.11";
}
