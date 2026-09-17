{
  description = "NixOS and nix-darwin configurations";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-26.05";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-darwin = {
      url = "github:nixos/nixpkgs/nixpkgs-26.05-darwin";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-unstable = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-hyprland = {
      url = "github:nixos/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    };
    nixpkgs-firefox = {
      url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    };
    wavefox = {
      url = "github:QNetITQ/WaveFox/0.6.155";
      flake = false;
    };
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix/3861e2249cb244bfbc7cfab2303c152cf5f9d9e9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware = {
      url = "github:nixos/nixos-hardware/d40fd26f323c898b0c195d41aa5efadd85f57832";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, mkHost, ... }:
      {
        systems = [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ];

        imports = [
          ./flake/checks.nix
          ./flake/devshell.nix
          ./flake/formatting.nix
          ./flake/hosts.nix
          ./flake/nixpkgs.nix
        ];

        flake = {
          nixosConfigurations = lib.genAttrs [
            "home"
            "katana"
            "media"
            "pi"
          ] mkHost.nixos;
          darwinConfigurations = lib.genAttrs [ "macbook" ] mkHost.darwin;
        };

        perSystem =
          { pkgs, ... }:
          {
            packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
              lib.genAttrs [
                "ai-usage"
                "ata-devs"
                "battery"
                "find-service"
                "git-commitu"
                "git-open-branch"
                "htop-vim-navigation"
                "pubip"
                "wallpaper-autopause"
                "wallpaper-randomize"
                "wallpaper-select"
                "wifi-connect"
                "zsh-claude-command"
              ] (name: pkgs.${name})
            );
          };
      }
    );
}
