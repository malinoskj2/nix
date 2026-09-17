# Provides mkHost.nixos and mkHost.darwin, which build hosts/<name>/configuration.nix with the
# platform's nixpkgs arguments and flake revision. flake.nix lists the hosts.
{
  inputs,
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
in
{
  _module.args.mkHost = {
    nixos = mkHost {
      builder = inputs.nixpkgs.lib.nixosSystem;
      platform = "linux";
    };

    darwin = mkHost {
      builder = inputs.nix-darwin.lib.darwinSystem;
      platform = "darwin";
    };
  };
}
