# Takes each local package from the overlaid pkgs, so every output is the derivation hosts install.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      names = lib.attrNames (import ../pkgs { inherit pkgs; });
    in
    {
      packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
        lib.genAttrs names (name: pkgs.${name})
      );
    };
}
