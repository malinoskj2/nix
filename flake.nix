{
  description = "NixOS configurations for home, katana, pi and media";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/936e4649098d6a5e0762058cb7687be1b2d90550";
    nixpkgs-hyprland.url = "github:nixos/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    nixpkgs-firefox.url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    wavefox = {
      url = "github:QNetITQ/WaveFox/0.6.155";
      flake = false;
    };
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix/69f20e9ba294420e4b6407a827c6b5aea3afcc12";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [ ./hosts ];

      flake.overlays = import ./overlays { inherit inputs; };
    };
}
