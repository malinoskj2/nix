{
  inputs,
  self,
  ...
}:
let
  mkNixpkgsArgs = extraOverlays: {
    config.allowUnfree = true;
    overlays = [
      self.overlays.additions
      self.overlays.unstable
    ]
    ++ extraOverlays;
  };
  nixpkgsArgs = {
    linux = mkNixpkgsArgs [
      self.overlays.pins
      inputs.apple-fonts.overlays.default
    ];
  };
in
{
  _module.args = { inherit nixpkgsArgs; };

  flake.overlays = import ../overlays { inherit inputs; };

  perSystem =
    { system, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs (nixpkgsArgs.linux // { inherit system; });
    };
}
