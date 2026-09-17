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
