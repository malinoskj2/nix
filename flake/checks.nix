{ lib, self, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      system,
      ...
    }:
    let
      hostsOnSystem = lib.filterAttrs (
        _: host: host.pkgs.stdenv.hostPlatform.system == system
      ) self.nixosConfigurations;
      localPackages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
        import ../pkgs { inherit pkgs; }
      );
      unexported = lib.subtractLists (lib.attrNames self'.packages) (lib.attrNames localPackages);
      hostChecks = lib.mapAttrs' (
        name: host: lib.nameValuePair "host-${name}" host.config.system.build.toplevel
      ) hostsOnSystem;
    in
    {
      checks =
        assert lib.assertMsg (unexported == [ ])
          "pkgs/ packages missing from exportedPackages in flake.nix: ${lib.concatStringsSep ", " unexported}";
        hostChecks
        // {
          devshell = self'.devShells.default;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          unreal-sandbox = self'.packages.agent-sandbox.unrealTests;
        };
    };
}
