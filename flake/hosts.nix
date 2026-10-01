{
  inputs,
  nixpkgsArgs,
  self,
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
  };
}
