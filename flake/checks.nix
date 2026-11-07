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
      onSystem = lib.filterAttrs (_: host: host.pkgs.stdenv.hostPlatform.system == system);
      nixosHosts = onSystem self.nixosConfigurations;
      unexported = lib.subtractLists (lib.attrNames self'.packages) (
        lib.attrNames (
          lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
            import ../pkgs { inherit pkgs; }
          )
        )
      );
      hostChecks = lib.mapAttrs' (
        name: host: lib.nameValuePair "host-${name}" host.config.system.build.toplevel
      ) nixosHosts;
    in
    {
      checks =
        assert lib.assertMsg (
          unexported == [ ]
        ) "pkgs/ packages missing from packages in flake.nix: ${lib.concatStringsSep ", " unexported}";
        hostChecks
        // {
          devshell = self'.devShells.default;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          unreal-sandbox = self'.packages.agent-sandbox.unrealTests;
        };
    };
}
