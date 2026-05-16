{ lib, ... }:

let
  vpnDir = "/secret/openvpn";
  authFile = "${vpnDir}/auth.txt";

  ovpnFiles =
    if builtins.pathExists vpnDir then
      lib.filter
        (name: lib.hasSuffix ".ovpn" name)
        (builtins.attrNames (builtins.readDir vpnDir))
    else
      [ ];

  serviceName = file:
    lib.strings.sanitizeDerivationName (lib.removeSuffix ".ovpn" file);

  mkServer = file: {
    name = serviceName file;
    value = {
      autoStart = false;
      updateResolvConf = true;
      authUserPass = authFile;
      config = ''
        config ${vpnDir}/${file}
      '';
    };
  };
in

{
  services.openvpn.servers = builtins.listToAttrs (map mkServer ovpnFiles);
}
