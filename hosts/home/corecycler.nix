{ pkgs, ... }:
let
  smuFiles = [
    "smu_args"
    "mp1_smu_cmd"
    "rsmu_cmd"
    "smn"
  ];
in
{
  environment.systemPackages = [ pkgs.corecycler ];

  # Lets jesse read MSRs and write Curve Optimizer offsets through ryzen_smu without sudo.
  # smn is arbitrary SMN register access.
  users.groups.corecycler = { };
  users.users.jesse.extraGroups = [ "corecycler" ];
  boot.kernelModules = [ "msr" ];
  services.udev.extraRules = ''
    SUBSYSTEM=="msr", KERNEL=="msr[0-9]*", GROUP="corecycler", MODE="0640"
  '';
  # The tuner pins each stress run with AllowedCPUs= on a user scope, which needs the user
  # manager to own the cpuset controller.
  # A systemd.services drop-in would also set PATH for the user manager.
  systemd.packages = [
    (pkgs.writeTextDir "lib/systemd/system/user@.service.d/corecycler-cpuset.conf" ''
      [Service]
      Delegate=cpu cpuset io memory pids
    '')
  ];

  systemd.services.corecycler-smu-permissions = {
    description = "Give the corecycler group access to ryzen_smu";
    after = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/sys/kernel/ryzen_smu_drv/smu_args";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = "/sys/kernel/ryzen_smu_drv";
      ExecStart = [
        "${pkgs.coreutils}/bin/chgrp corecycler ${toString smuFiles}"
        "${pkgs.coreutils}/bin/chmod 0660 ${toString smuFiles}"
      ];
    };
  };
}
