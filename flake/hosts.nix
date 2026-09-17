{
  inputs,
  lib,
  nixpkgsArgs,
  self,
  ...
}:
let
  common = platform: {
    nixpkgs = nixpkgsArgs.${platform};
    system.configurationRevision = self.rev or self.dirtyRev or null;
  };

  mkNixos =
    name:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        (common "linux")
        ../hosts/${name}/configuration.nix
      ];
    };

  mkDarwin =
    name:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs; };
      modules = [
        (common "darwin")
        ../hosts/${name}/configuration.nix
      ];
    };
in
{
  flake = {
    nixosConfigurations = lib.genAttrs [ "home" "katana" "media" "pi" ] mkNixos;
    darwinConfigurations = lib.genAttrs [ "macbook" ] mkDarwin;
  };
}
