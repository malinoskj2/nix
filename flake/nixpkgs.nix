# Exports the overlays and defines each platform's nixpkgs arguments, which both the hosts
# and perSystem's pkgs use, so per-system outputs build what the hosts install.
{
  inputs,
  lib,
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
    # Pins and the Apple fonts serve only the Linux desktops; see docs/updating.md.
    linux = mkNixpkgsArgs [
      self.overlays.pins
      inputs.apple-fonts.overlays.default
    ];

    darwin = mkNixpkgsArgs [ ];
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
