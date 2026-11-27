{ pkgs, ... }:
{
  # gVisor's user-space kernel, for review Compose stacks the agent sandboxes' runner starts. They
  # never get the GPU, so this doesn't need a runsc whose nvproxy knows the host driver.
  virtualisation.docker.daemon.settings.runtimes.runsc = {
    path = "${pkgs.gvisor}/bin/runsc";
    # Docker's embedded DNS answers at 127.0.0.11 through NAT rules in the container's netns, which
    # iptables-nft writes as nftables; gVisor's own network stack sees them only when it copies them.
    runtimeArgs = [ "--reproduce-nftables" ];
  };
}
