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
        claude-code = unstablePkgs.claude-code.override {
          # The wrapper puts alsa-lib on LD_LIBRARY_PATH, which every command Claude runs inherits.
          # Unstable's build needs a newer glibc than release programs that load libasound have.
          inherit (final) alsa-lib;
        };
      };
    };

  pins = final: _prev: {
    inherit (importNixpkgs inputs.nixpkgs-firefox final) firefox;
    inherit (importNixpkgs inputs.nixpkgs-hyprland final)
      hyprland
      hyprpicker
      xdg-desktop-portal-hyprland
      ;
  };
}
