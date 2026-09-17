{
  description = "NixOS and nix-darwin configurations";

  inputs = {
    # These three follow the same NixOS release as nixpkgs-darwin and nix-darwin
    # below, and all five move together; see docs/updating.md.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Same release as nixpkgs; see docs/updating.md.
    nixpkgs-darwin.url = "github:nixos/nixpkgs/nixpkgs-26.05-darwin";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };

    # Exposed as pkgs.unstable for selected packages.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Exact revision: Hyprland, its plugins and the portal move with the version
    # assertions and the hyprfocus patches; see docs/updating.md.
    nixpkgs-hyprland.url = "github:nixos/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";

    # Exact revision: Firefox's major version must match wavefox; see docs/updating.md.
    nixpkgs-firefox.url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    wavefox = {
      url = "github:QNetITQ/WaveFox/0.6.155";
      flake = false;
    };

    # Exact commit: pi's Raspberry Pi 4 kernel and firmware; bump only with a device test.
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/d40fd26f323c898b0c195d41aa5efadd85f57832";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Exact commit: its lock records Apple's .dmg hashes, which Apple replaces in
    # place. Bump it when a fetch fails with a hash mismatch; see docs/updating.md.
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix/3861e2249cb244bfbc7cfab2303c152cf5f9d9e9";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        ./flake/checks.nix
        ./flake/devshell.nix
        ./flake/formatting.nix
        ./flake/hosts.nix
        ./flake/nixpkgs.nix
        ./flake/packages.nix
      ];
    };
}
