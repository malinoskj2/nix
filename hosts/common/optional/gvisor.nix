{
  config,
  lib,
  pkgs,
  ...
}:
let
  # --reproduce-nftables copies the netns's nftables NAT rules through iptables-nft-save and
  # iptables-legacy-restore, so runsc needs both on PATH; without them it falls back to reading the
  # legacy tables, and when those don't exist every container fails to start.
  runsc = pkgs.writeShellScript "runsc" ''
    PATH=${lib.makeBinPath [ config.networking.firewall.package ]}:$PATH
    exec ${pkgs.gvisor}/bin/runsc "$@"
  '';
in
{
  # gVisor's user-space kernel, for review Compose stacks the agent sandboxes' runner starts. They
  # never get the GPU, so this doesn't need a runsc whose nvproxy knows the host driver.
  virtualisation.docker.daemon.settings.runtimes.runsc = {
    path = "${runsc}";
    # Docker's embedded DNS answers at 127.0.0.11 through NAT rules in the container's netns, which
    # iptables-nft writes as nftables; gVisor's own network stack sees them only when it copies them.
    runtimeArgs = [ "--reproduce-nftables" ];
  };

  # The copy goes through the legacy NAT table of each container's netns.
  boot.kernelModules = [
    "ip_tables"
    "iptable_nat"
  ];
}
