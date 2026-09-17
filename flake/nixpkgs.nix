# How nixpkgs is instantiated. Hosts get these arguments through their nixpkgs
# options (flake/hosts.nix) and perSystem pkgs through `import`, so packages,
# checks and the devshell build exactly what the hosts build.
{
  inputs,
  lib,
  self,
  ...
}:
let
  nixpkgsArgs = {
    linux = {
      config.allowUnfree = true;
      overlays = [
        self.overlays.additions
        inputs.apple-fonts.overlays.default
        self.overlays.unstable
        self.overlays.pins
      ];
    };
    # pins takes Linux-only packages from Linux nixpkgs revisions.
    darwin = {
      config.allowUnfree = true;
      overlays = [
        self.overlays.additions
        self.overlays.unstable
      ];
    };
  };
in
{
  _module.args = { inherit nixpkgsArgs; };

  flake.overlays = import ../overlays { inherit inputs; };

  perSystem =
    { system, ... }:
    {
      _module.args.pkgs =
        if (lib.systems.elaborate system).isDarwin then
          import inputs.nixpkgs-darwin (nixpkgsArgs.darwin // { inherit system; })
        else
          import inputs.nixpkgs (nixpkgsArgs.linux // { inherit system; });
    };
}
