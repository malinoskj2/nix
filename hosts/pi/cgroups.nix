# Memory and swap cgroup accounting, which Docker's container resource limits rely on.
{
  boot.kernelParams = [
    "cgroup_enable=memory"
    "swapaccount=1"
  ];

  systemd.settings.Manager = {
    DefaultBlockIOAccounting = true;
    DefaultCPUAccounting = true;
    DefaultMemoryAccounting = true;
    DefaultTasksAccounting = true;
  };
}
