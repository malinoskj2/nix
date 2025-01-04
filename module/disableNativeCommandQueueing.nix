{ lib, config, pkgs, options, ... }:
with lib;
let cfg = config.boot.nativeCommandQueueing;
in {
  options.boot.nativeCommandQueueing = {
    disable = mkEnableOption "Native Command Queueing";
  };

  config = mkIf cfg.disable { boot.kernelParams = [ "libata.force=noncq" ]; };
}
