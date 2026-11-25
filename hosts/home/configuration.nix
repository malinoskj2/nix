{
  config,
  inputs,
  pkgs,
  ...
}:
let
  sandboxCpus = {
    # Everything except two CCD0 cores and their SMT siblings, kept for the desktop.
    idle = "2-15,18-31";
    # CCD1 only, while GameMode pins a game to CCD0.
    gaming = "8-15,24-31";
  };
  setSandboxCpus =
    cpus:
    "${config.systemd.package}/bin/systemctl set-property --runtime agent-sandbox.slice AllowedCPUs=${cpus}";
  gamingUnit = "agent-sandbox-gaming.service";
in
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
    ./corecycler.nix
    ./gaming.nix
    ./greeter.nix
    ./host-switch.nix
    ./external-ssd.nix
    ./media-share.nix
    ./memory-notifications.nix
    ./nvidia.nix
    ./obs.nix
    ./scheduler.nix
  ];

  networking = {
    hostName = "home";

    # Tohru's network panel talks to NetworkManager over D-Bus, so
    # NetworkManager owns the interfaces and creates the wired DHCP profile.
    networkmanager.enable = true;

    firewall.enable = false;
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 32 * 1024;
    }
  ];

  nix.settings = {
    # Run one build at a time so parallel builds don't multiply the core budget.
    max-jobs = 1;
    cores = 8;
  };

  security.sudo.extraRules = [
    {
      users = [ "jesse" ];
      # nh refuses to run as root, and elevates each step itself through env.
      commands =
        map
          (command: {
            inherit command;
            options = [ "NOPASSWD" ];
          })
          [
            "/run/current-system/sw/bin/nixos-rebuild"
            "/run/current-system/sw/bin/env * /nix/store/*-nixos-system-*/bin/switch-to-configuration *"
            "/run/current-system/sw/bin/env * --profile /nix/var/nix/profiles/system *"
          ];
    }
  ];

  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "14G";
    MemoryMax = "16G";
  };

  # agent-sandbox runs its containers under this slice.
  systemd.slices.agent-sandbox = {
    # Keep the cgroup available for the launcher's read-only stats mount, even
    # before the first container starts.
    wantedBy = [ "multi-user.target" ];
    sliceConfig = {
      AllowedCPUs = sandboxCpus.idle;

      # No MemoryHigh: once swap is full it can't reclaim anon memory and throttles
      # every sandbox indefinitely instead of killing anything. MemoryMax reclaims
      # too, then OOM-kills the largest process.
      MemoryMax = "60G";

      # Swapping out idle agents and display stacks beats OOM-killing a build.
      MemorySwapMax = "16G";
    };
  };

  # The desktop isn't capped, so this only decides who gets reclaimed first
  # when the sandboxes and nix-daemon together outgrow RAM.
  systemd.slices.user.sliceConfig.MemoryLow = "16G";

  systemd.services.agent-sandbox-gaming = {
    description = "Keep agent sandboxes off the V-Cache CCD while a game runs";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setSandboxCpus sandboxCpus.gaming;
      ExecStop = setSandboxCpus sandboxCpus.idle;
    };
  };

  # GameMode's hooks run in jesse's user daemon.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (
        action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "${gamingUnit}" &&
        ["start", "stop"].indexOf(action.lookup("verb")) >= 0 &&
        subject.user == "jesse"
      ) {
        return polkit.Result.YES;
      }
    });
  '';

  programs.gamemode.settings.custom = {
    start = "${config.systemd.package}/bin/systemctl --no-ask-password start ${gamingUnit}";
    end = "${config.systemd.package}/bin/systemctl --no-ask-password stop ${gamingUnit}";
  };

  programs.nix-index-database.comma.enable = true;

  services.printing = {
    enable = true;
    drivers = [ pkgs.hplipWithPlugin ];
    browsed.enable = true;
    browsedConf = ''
      BrowseRemoteProtocols dnssd
      CreateIPPPrinterQueues All
    '';
  };

  # Discover driverless USB printers (including the DeskJet 2800) and LAN printers.
  services.ipp-usb.enable = true;
  # Also discover printers already connected when this configuration is activated.
  # With no printer connected, ipp-usb stays idle and watches for USB hotplug.
  systemd.services.ipp-usb.wantedBy = [ "multi-user.target" ];
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  environment.systemPackages = with pkgs; [
    agent-sandbox
    gpu-scheduler
    switch-and-reset-sandboxes
    libva-utils

    # Pulls in the full .NET SDK, so only this host installs it.
    source2viewer-cli
  ];

  system.stateVersion = "25.11";
}
