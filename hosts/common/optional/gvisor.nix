{ pkgs, ... }:
{
  # gVisor's user-space kernel, for review Compose stacks the agent sandboxes' runner starts. They
  # never get the GPU, so this doesn't need a runsc whose nvproxy knows the host driver.
  virtualisation.docker.daemon.settings.runtimes.runsc = {
    path = "${pkgs.gvisor}/bin/runsc";
    # Docker's embedded DNS listens on the host kernel's loopback in each container's netns, which
    # gVisor's own network stack can't reach, so services couldn't resolve each other. With host
    # networking the sandbox makes its sockets in that netns (never the host's: the runner only
    # allows networks that give the container its own), and every other syscall stays in gVisor.
    runtimeArgs = [ "--network=host" ];
  };
}
