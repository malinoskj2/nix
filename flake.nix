{
  description = "NixOS and Home Manager configurations";

  inputs = {
    apple-fonts = {
      type = "github";
      owner = "Lyndeno";
      repo = "apple-fonts.nix";
      rev = "58b7ab5a049c57c4f38f27eac84f45e2903bb687";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      type = "github";
      owner = "catppuccin";
      repo = "nix";
      ref = "release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      type = "github";
      owner = "hercules-ci";
      repo = "flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    home-manager = {
      type = "github";
      owner = "nix-community";
      repo = "home-manager";
      ref = "release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      type = "github";
      owner = "nix-community";
      repo = "nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware = {
      type = "github";
      owner = "nixos";
      repo = "nixos-hardware";
      rev = "d40fd26f323c898b0c195d41aa5efadd85f57832";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      ref = "nixos-26.05";
    };
    nixpkgs-firefox = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      rev = "2786a2a72088ecf32aea5b3ec52099e6a7cff78f";
    };
    nixpkgs-hyprland = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      rev = "2786a2a72088ecf32aea5b3ec52099e6a7cff78f";
    };
    nixpkgs-unstable = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      ref = "nixos-unstable";
    };
    tohru = {
      type = "github";
      owner = "malinoskj2";
      repo = "tohru";
      rev = "1e84114100d6604cbb9ccc603ee5ccadb1f8f787";
      # Its plugin must build against the same Hyprland as the desktop.
      inputs.hyprland-nixpkgs.follows = "nixpkgs-hyprland";
    };
    treefmt-nix = {
      type = "github";
      owner = "numtide";
      repo = "treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wavefox = {
      type = "github";
      owner = "QNetITQ";
      repo = "WaveFox";
      ref = "0.9.160";
      flake = false;
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (
      { lib, mkHost, ... }:
      let
        systems = [
          "aarch64-linux"
          "x86_64-linux"
        ];
        nixosHosts = [
          "home"
          "katana"
          "mac-vm"
          "media"
          "pi"
        ];
        exportedPackages = [
          "cargo-preferences"
          "agent-sandbox"
          "ai-usage"
          "antigravity-cli"
          "ata-devs"
          "battery"
          "discord-context"
          "find-service"
          "frame-interpolation"
          "game-background-engine"
          "game-background-limit"
          "game-latency-check"
          "game-workspace-audio"
          "git-commitu"
          "git-open-branch"
          "gpu-scheduler"
          "host-switch"
          "htop-vim-navigation"
          "hy3dgen"
          "hyprland-quit"
          "last30days"
          "local-models"
          "markdown-to-pdf"
          "media-gallery"
          "media-transcribe"
          "mpvpaper-vk"
          "orca-ade"
          "playwright-browsers"
          "pubip"
          "pyghidra-mcp"
          "qwen-prompt"
          "switch-and-reset-sandboxes"
          "tiktok-search"
          "wallpaper-autopause"
          "wallpaper-outputs"
          "wallpaper-play"
          "wallpaper-randomize"
          "wifi-connect"
          "zsh-claude-command"
        ];
      in
      {
        inherit systems;

        imports = [
          ./flake/checks.nix
          ./flake/devshell.nix
          ./flake/formatting.nix
          ./flake/hosts.nix
          ./flake/nixpkgs.nix
        ];

        flake.nixosConfigurations = lib.genAttrs nixosHosts mkHost.nixos;

        perSystem =
          { pkgs, ... }:
          {
            packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
              lib.getAttrs exportedPackages pkgs
            );
          };
      }
    );
}
