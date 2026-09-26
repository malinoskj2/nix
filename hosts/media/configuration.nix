{ inputs, pkgs, ... }:
{
  imports = [
    inputs.media-stack.nixosModules.default

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
    ./nvidia.nix
    ./storage.nix
  ];

  services.media-stack = {
    enable = true;
    configDir = "/home/jesse/docker_cfg2";
    dataDir = "/media/data";
    legacyDir = "/media/storage/media";
    anime4Dir = "/mnt/media4/anime";
  };

  networking = {
    hostName = "media";
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
    ];
    firewall.allowPing = false;
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

  users = {
    mutableUsers = false;

    # Read at activation, so the hash stays out of the store. If the file is
    # missing, jesse's password is locked and sudo stops working.
    users.jesse.hashedPasswordFile = "/secret/jesse.passwd";
  };

  security = {
    sudo.execWheelOnly = true;

    # Docker confines every container with its docker-default profile once
    # AppArmor is on, and loads that profile with apparmor_parser.
    apparmor.enable = true;
  };
  systemd.services.docker.path = [ pkgs.apparmor-parser ];

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
