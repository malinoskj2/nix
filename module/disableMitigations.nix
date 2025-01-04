{ lib, config, pkgs, options, ... }:
with lib;
let cfg = config.boot.mitigations;
in {
  options.boot.mitigations = {
    disable = mkEnableOption "Spectre / Meltdown Mitigations";
  };

  config = mkIf cfg.disable {
    boot.kernelParams = [
      "l1tf=off"
      "mds=off"
      "mitigations=off"
      "no_stf_barrier"
      "noibpb"
      "noibrs"
      "nopti"
      "nospec_store_bypass_disable"
      "nospectre_v1"
      "nospectre_v2"
      "tsx=on"
      "tsx_async_abort=off"
      "mitigations=off"
    ];
  };
}
