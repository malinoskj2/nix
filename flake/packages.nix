{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
        lib.getAttrs (lib.attrNames (import ../pkgs { inherit pkgs; })) pkgs
      );
    };
}
