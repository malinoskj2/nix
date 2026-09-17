# media: Intel desktop with an RTX 3060 Ti, running the Docker media stack
# (Plex, *arr, Caddy) with Seerr exposed to the internet.
{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./storage.nix
    ./nvidia.nix

    ../common/global.nix
    ../common/users/jesse
    ../common/optional/docker.nix
    ../common/optional/fail2ban.nix
    ../common/optional/nh.nix
    ../common/optional/openssh-hardened.nix
    ../common/optional/server-tools.nix
    ../common/optional/sysctl-hardening.nix
    ../common/optional/systemd-boot.nix

    ./media-stack.nix
  ];

  boot.kernel.sysctl."vm.swappiness" = 10;

  networking = {
    hostName = "media";
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
    ];
    firewall = {
      allowPing = false;
      allowedTCPPorts = [
        80
        443
        32400
      ];
    };
  };

  # Accounts come only from this config, and jesse has no password: if the key
  # is lost, recovery needs console access and a rebuild or boot into an old generation.
  users.mutableUsers = false;

  security.sudo = {
    wheelNeedsPassword = false;
    execWheelOnly = true;
  };

  services.openssh = {
    ports = [ 2222 ];
    settings.AllowUsers = [ "jesse" ];
  };

  # nix.gc owns cleanup here instead of nh.
  programs.nh.clean.enable = false;

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 21d";
    };
    settings.auto-optimise-store = true;
  };

  environment.systemPackages = with pkgs; [
    curl
    dnsutils
    lazydocker
    nvtopPackages.nvidia
    smartmontools
    tmux
  ];

  system.stateVersion = "25.11";
}
