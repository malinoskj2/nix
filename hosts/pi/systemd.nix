# Systemd
_:

{
  systemd.settings.Manager = {
    DefaultCPUAccounting = true;
    DefaultIOAccounting = true;
    DefaultBlockIOAccounting = true;
    DefaultMemoryAccounting = true;
    DefaultTasksAccounting = true;
  };
}
