{ lib, config, pkgs, options, ... }:
with lib;
let cfg = config.boot.mitigations;
in {
  options.blockDevices.ioScheduling = {
    disable = mkEnableOption "IO Scheduler";
  };

  config = mkIf cfg.disable {
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="[sv]d[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
    '';
  };
}
