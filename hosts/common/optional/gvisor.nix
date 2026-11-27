{ pkgs, ... }:
{
  # gVisor's user-space kernel, for review Compose stacks the agent sandboxes' runner starts. They
  # never get the GPU, so this doesn't need a runsc whose nvproxy knows the host driver.
  virtualisation.docker.daemon.settings.runtimes.runsc.path = "${pkgs.gvisor}/bin/runsc";
}
