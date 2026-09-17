{ self, lib, ... }:
{
  perSystem =
    { self', system, ... }:
    let
      hosts = lib.filterAttrs (_: host: host.pkgs.stdenv.hostPlatform.system == system) (
        self.nixosConfigurations // self.darwinConfigurations
      );

      # What hosts on this system install directly, system-wide or through Home Manager.
      installed = lib.concatMap (
        host:
        host.config.environment.systemPackages
        ++ lib.concatMap (user: user.home.packages) (lib.attrValues (host.config.home-manager.users or { }))
      ) (lib.attrValues hosts);
      isInstalled = package: lib.any (p: (p.outPath or null) == package.outPath) installed;
    in
    {
      checks =
        lib.mapAttrs' (name: host: lib.nameValuePair "host-${name}" host.config.system.build.toplevel) hosts
        // lib.mapAttrs' (name: lib.nameValuePair "package-${name}") (
          lib.filterAttrs (_: isInstalled) self'.packages
        )
        // {
          devshell = self'.devShells.default;
        };
    };
}
