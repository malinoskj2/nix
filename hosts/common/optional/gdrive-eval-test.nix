{ pkgs, config }:
let
  inherit (pkgs) lib;
  names = [
    "gdrive-client-id"
    "gdrive-client-secret"
    "gdrive-token"
  ];
  unit = config.systemd.services.gdrive-mount;
  secretPaths = map (name: config.secrets.host.${name}.path) names;
  cases = {
    host-secrets = lib.all (
      name:
      let
        s = config.secrets.host.${name};
      in
      s.owner == "gdrive" && s.mode == "0400" && s.restartUnits == [ "gdrive-mount.service" ]
    ) names;
    waits-for-every-secret =
      lib.sort lib.lessThan unit.unitConfig.ConditionPathExists == lib.sort lib.lessThan secretPaths
      && lib.elem "sops-install-secrets.service" unit.after;
    started-after-unlock = lib.elem "gdrive-mount.service" config.secrets.startUnits;
    runs-as-gdrive = unit.serviceConfig.User == "gdrive";
    no-credentials-in-environment = lib.all (
      key: !(lib.hasInfix "CLIENT_ID" key || lib.hasInfix "SECRET" key || lib.hasInfix "TOKEN" key)
    ) (lib.attrNames unit.environment);
    no-network-online-wait =
      !(lib.elem "network-online.target" (unit.after ++ unit.wants ++ unit.requires));
    restarts-forever =
      unit.serviceConfig.Restart == "on-failure" && unit.unitConfig.StartLimitIntervalSec == 0;
    gdrive-group-is-private = config.users.groups.gdrive.members == [ ];
    jesse-outside-gdrive = !(lib.elem "gdrive" config.users.users.jesse.extraGroups);
  };
  broken = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
in
assert lib.assertMsg (
  broken == [ ]
) "gdrive eval cases failed: ${lib.concatStringsSep ", " broken}";
pkgs.runCommand "gdrive-eval" { } "touch $out"
