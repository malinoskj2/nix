# Builds hosts/<name>/configuration.nix with the platform's nixpkgs arguments and flake revision.
{
  inputs,
  lib,
  nixpkgsArgs,
  self,
  ...
}:
let
  mkHost =
    { builder, platform }:
    name:
    builder {
      specialArgs = { inherit inputs; };
      modules = [
        {
          nixpkgs = nixpkgsArgs.${platform};
          system.configurationRevision = self.rev or self.dirtyRev or null;
        }
        ../hosts/${name}/configuration.nix
      ];
    };

  mkNixos = mkHost {
    builder = inputs.nixpkgs.lib.nixosSystem;
    platform = "linux";
  };

  mkDarwin = mkHost {
    builder = inputs.nix-darwin.lib.darwinSystem;
    platform = "darwin";
  };
in
{
  flake = {
    nixosConfigurations = lib.genAttrs [
      "home"
      "katana"
      "media"
      "pi"
    ] mkNixos;

    darwinConfigurations = lib.genAttrs [ "macbook" ] mkDarwin;
  };
}
