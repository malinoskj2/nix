{ pkgs, ... }:
{
  imports = [
    ../common/global.nix
    ../common/optional/docker.nix
    ../common/optional/fail2ban.nix
    ../common/optional/nh.nix
    ../common/optional/openssh-hardening.nix
    ../common/optional/server-tools.nix
    ../common/optional/sysctl-hardening.nix
    ../common/optional/systemd-boot.nix
    ../common/users/jesse

    ./hardware-configuration.nix
    ./media-stack.nix
    ./nvidia.nix
    ./storage.nix
  ];

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

  nix = {
    settings.auto-optimise-store = true;

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 21d";
    };
  };

  boot.kernel.sysctl."vm.swappiness" = 10;

  # Accounts come only from this config, and jesse has no password: if the key is
  # lost, recovery needs console access and a rebuild or a boot into an old generation.
  users.mutableUsers = false;

  security.sudo = {
    execWheelOnly = true;
    wheelNeedsPassword = false;
  };

  services.openssh = {
    ports = [ 2222 ];
    settings.AllowUsers = [ "jesse" ];
  };

  # nix.gc cleans the store on this host instead.
  programs.nh.clean.enable = false;

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
