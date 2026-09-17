{
  inputs,
  nixpkgsArgs,
  self,
  withSystem,
  ...
}:
{
  _module.args.mkHost = {
    nixos =
      name:
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          {
            nixpkgs = nixpkgsArgs.linux;
            system.configurationRevision = self.rev or self.dirtyRev or null;
          }
          ../hosts/${name}/configuration.nix
        ];
      };
    darwin =
      name:
      withSystem "aarch64-darwin" (
        { pkgs, ... }:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit inputs; };
          modules = [
            inputs.catppuccin.homeModules.catppuccin
            ../users/jesse/profiles/${name}.nix
          ];
        }
      );
  };
}
