{
  description = ":)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    neowall-src = {
      url = "github:1ay1/neowall";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    utils.url = "github:gytis-ivaskevicius/flake-utils-plus";
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
    nixpkgs-hyprland.url = "github:nixos/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    nixpkgs-firefox.url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    wavefox = {
      url = "github:QNetITQ/WaveFox/0.6.155";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
      home-manager,
      nix-index-database,
      catppuccin,
      ...
    }@inputs:
    utils.lib.mkFlake {
      inherit self inputs;

      channelsConfig.allowUnfree = true;
      sharedOverlays = [
        (final: prev: {
          inherit (inputs.nixpkgs-hyprland.legacyPackages.${prev.stdenv.hostPlatform.system})
            hyprland
            hyprlandPlugins
            xdg-desktop-portal-hyprland
            ;
        })
        (import ./overlays/derivations.nix)
        (final: prev: {
          inherit (inputs.nixpkgs-firefox.legacyPackages.${prev.stdenv.hostPlatform.system})
            firefox
            ;
        })
      ];
      hostDefaults.modules = [
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.backupFileExtension = "hm-bak";
          home-manager.sharedModules = [ catppuccin.homeModules.catppuccin ];
        }
      ];

      hosts.home = {
        system = "x86_64-linux";
        modules = [
          ./hosts/home/configuration.nix
          nix-index-database.nixosModules.nix-index
          { programs.nix-index-database.comma.enable = true; }
          {
            home-manager.users.jesse.imports = [
              ./users/jesse
              ./users/jesse/desktop-home
            ];
          }
        ];
        specialArgs = {
          secrets = import /secret/secrets.nix;
        };
      };

      hosts.katana = {
        system = "x86_64-linux";
        modules = [
          ./hosts/katana/configuration.nix
          { home-manager.users.jesse = import ./users/jesse; }
        ];
      };

      hosts.pi = {
        system = "aarch64-linux";
        modules = [ ./hosts/pi/configuration.nix ];
      };

      hosts.media = {
        system = "x86_64-linux";
        modules = [ ./hosts/media/configuration.nix ];
        specialArgs = {
          secrets = import /secret/secrets.nix;
        };
      };
    };
}
