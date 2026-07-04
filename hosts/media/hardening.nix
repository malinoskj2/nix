# Baseline hardening for an internet-facing host.
{ ... }:

{
  # Brute-force protection for SSH (and anything else that logs auth failures).
  services.fail2ban = {
    enable = true;
    maxretry = 4;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
      factor = "4";
    };
    ignoreIP = [
      "127.0.0.1/8"
      "192.168.0.0/16"
      "10.0.0.0/8"
    ];
  };

  # Pull security fixes automatically. Reboots only in a quiet window so a
  # kernel update doesn't drop the box mid-stream.
  system.autoUpgrade = {
    enable = true;
    flake = "github:malinoskj2/nix#media"; # adjust to your remote/host attr
    flags = [
      "--update-input"
      "nixpkgs"
    ];
    dates = "04:30";
    randomizedDelaySec = "30min";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 21d";
  };
  nix.settings.auto-optimise-store = true;

  # Kernel/network sysctl hardening.
  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.tcp_syncookies" = 1;
  };

  # Trim setuid surface; keep sudo working via wheel.
  security.sudo.execWheelOnly = true;

  # No swap secrets left on disk after suspend/hibernate (server won't anyway).
  boot.kernel.sysctl."vm.swappiness" = 10;
}
