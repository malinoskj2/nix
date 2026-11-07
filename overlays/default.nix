{ inputs }:
let
  # Imports another nixpkgs source with the platform and config of pkgs, so allowUnfree reaches it.
  importNixpkgs =
    nixpkgs: pkgs:
    import nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (pkgs) config;
    };
in
{
  additions =
    final: _prev:
    import ../pkgs {
      pkgs = final;
    };

  unstable =
    final: _prev:
    let
      unstablePkgs = importNixpkgs inputs.nixpkgs-unstable final;
    in
    {
      unstable = unstablePkgs // {
        # TODO: drop this override and the manifest once nixpkgs-unstable reaches 2.1.319.
        claude-code = unstablePkgs.claude-code.override {
          manifest = final.lib.importJSON ./claude-code/manifest.zst.json;
        };
      };
    };

  pins = final: _prev: {
    inherit (importNixpkgs inputs.nixpkgs-firefox final) firefox;
    inherit (importNixpkgs inputs.nixpkgs-hyprland final) hyprland xdg-desktop-portal-hyprland;
  };
}
