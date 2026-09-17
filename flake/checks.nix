# Builds this system's hosts, the local packages they install directly and the devshell, and
# fails if a package in pkgs/ available on this system is missing from flake.nix's packages.
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
      hosts = lib.filterAttrs (_: host: host.pkgs.stdenv.hostPlatform.system == system) (
        self.nixosConfigurations // self.darwinConfigurations
      );

      hostPackages =
        host:
        let
          users = lib.attrValues (host.config.home-manager.users or { });
        in
        host.config.environment.systemPackages ++ lib.concatMap (user: user.home.packages) users;

      installedPaths = lib.catAttrs "outPath" (lib.concatMap hostPackages (lib.attrValues hosts));

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
      ) hosts;

      packageChecks = lib.mapAttrs' (
        name: package: lib.nameValuePair "package-${name}" package
      ) installedPackages;
    in
    {
      checks =
        assert lib.assertMsg (
          unexported == [ ]
        ) "pkgs/ packages missing from packages in flake.nix: ${lib.concatStringsSep ", " unexported}";
        hostChecks // packageChecks // { devshell = self'.devShells.default; };
    };
}
