{ inputs, pkgs, ... }:
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
    ../common/optional/workstation.nix
    ../common/users/jesse
    ../common/users/jesse/interactive.nix

    ./hardware-configuration.nix
    ./boot.nix
    ./gaming.nix
    ./memory-notifications.nix
    ./nvidia.nix
    ./obs.nix
    ./scheduler.nix
  ];

  networking = {
    hostName = "home";

    # j2bar's network source talks to NetworkManager over D-Bus, so
    # NetworkManager owns the interfaces and creates the wired DHCP profile.
    networkmanager.enable = true;

    # Orca's LAN listener for the mobile app.
    firewall.interfaces.enp8s0.allowedTCPPorts = [ 6768 ];
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024;
    }
  ];

  zramSwap.enable = true;
  # Zram takes swap before the swapfile, so swapping out is cheap, but past 100 the kernel would
  # prefer it to dropping cache and spill idle apps onto the swapfile once zram fills.
  boot.kernel.sysctl."vm.swappiness" = 100;

  nix.settings = {
    max-jobs = 16;
    cores = 16;
  };

  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "20G";
    MemoryMax = "24G";
  };

  # agent-sandbox runs its containers under this slice. No MemoryHigh: once swap
  # is full it can't reclaim anon memory and throttles every sandbox indefinitely
  # instead of killing anything. MemoryMax reclaims too, then OOM-kills the
  # largest process. A little swap lets reclaim page out tmpfs.
  systemd.slices.agent-sandbox.sliceConfig = {
    # CCD1 has 32 MiB L3, without V-Cache. Include its SMT siblings and
    # constrain every container in this slice; the desktop can use both CCDs.
    AllowedCPUs = "8-15,24-31";
    MemoryMax = "20G";
    MemorySwapMax = "4G";
  };

  programs.nix-index-database.comma.enable = true;

  environment.systemPackages = with pkgs; [
    agent-sandbox
    switch-and-reset-sandboxes
    libva-utils

    # Pulls in the full .NET SDK, so only this host installs it.
    source2viewer-cli
  ];

  system.stateVersion = "25.11";
}
