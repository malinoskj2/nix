# Kept pending on-device verification; likely obsolete on systemd 260 and the
# rpi 6.18 kernel, which enable these controllers and accounting by default.
{
  boot.kernelParams = [
    "cgroup_enable=memory"
    "swapaccount=1"
  ];

  systemd.settings.Manager = {
    DefaultCPUAccounting = true;
    DefaultBlockIOAccounting = true;
    DefaultMemoryAccounting = true;
    DefaultTasksAccounting = true;
  };
}
