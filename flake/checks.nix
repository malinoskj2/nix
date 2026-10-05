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
      hostPackages =
        host:
        let
          users = lib.attrValues (host.config.home-manager.users or { });
        in
        host.config.environment.systemPackages ++ lib.concatMap (user: user.home.packages) users;
      installedPaths = lib.catAttrs "outPath" (lib.concatMap hostPackages (lib.attrValues nixosHosts));
      installedPackages = lib.filterAttrs (
        _: package: lib.elem package.outPath installedPaths
      ) self'.packages;
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
      packageChecks = lib.mapAttrs' (
        name: package: lib.nameValuePair "package-${name}" package
      ) installedPackages;
    in
    {
      checks =
        assert lib.assertMsg (
          unexported == [ ]
        ) "pkgs/ packages missing from packages in flake.nix: ${lib.concatStringsSep ", " unexported}";
        hostChecks
        // packageChecks
        // {
          devshell = self'.devShells.default;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          unreal-sandbox = self'.packages.agent-sandbox.unrealTests;
        };
    };
}
