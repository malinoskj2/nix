{
  description = "NixOS and Home Manager configurations";

  inputs = {
    apple-fonts = {
      type = "github";
      owner = "Lyndeno";
      repo = "apple-fonts.nix";
      rev = "3861e2249cb244bfbc7cfab2303c152cf5f9d9e9";
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
    # j2bar has no remote, so the input is the local repository. It is built against the nixpkgs
    # Hyprland comes from, which its own flake pins too.
    j2bar = {
      type = "git";
      url = "file:///home/jesse/projects/j2bar";
      ref = "master";
      inputs.nixpkgs.follows = "nixpkgs-hyprland";
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
      rev = "21a67dc470149f337cecafbe965d8d252a390518";
    };
    nixpkgs-hyprland = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      rev = "8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    };
    nixpkgs-unstable = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      ref = "nixos-unstable";
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
      ref = "0.6.155";
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
          "media"
          "pi"
        ];
        packages = [
          "agent-sandbox"
          "ai-usage"
          "ata-devs"
          "battery"
          "claude-desktop"
          "find-service"
          "game-latency-check"
          "git-commitu"
          "git-open-branch"
          "htop-vim-navigation"
          "hy3dgen"
          "hyprglass"
          "hyprland-quit"
          "hyprsheet"
          "markdown-to-pdf"
          "orca-ade"
          "pubip"
          "wallpaper-autopause"
          "wallpaper-outputs"
          "wallpaper-play"
          "wallpaper-randomize"
          "wallpaper-select"
          "wifi-connect"
          "zcode"
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

        flake = {
          nixosConfigurations = lib.genAttrs nixosHosts mkHost.nixos;
        };

        perSystem =
          { pkgs, ... }:
          {
            packages = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (
              lib.getAttrs packages pkgs
            );
          };
      }
    );
}
