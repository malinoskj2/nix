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
    # Hyprland (0.55.4) and its plugins come from this exact nixpkgs rev so `nix flake update`
    # can't move them; the hyprfocus patches rely on Hyprland internals. Bump deliberately.
    nixpkgs-hyprland.url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    # Adds Hyprbars title font weight without crossing into its Hyprland 0.56 API changes.
    hyprland-plugins-src = {
      url = "github:hyprwm/hyprland-plugins/1cb37fad68dff5f5840010c314fed5809b4ee66f";
      flake = false;
    };
    # Firefox comes from this exact nixpkgs rev (155.0.1) so `nix flake update` can't
    # move it out from under WaveFox. Bump this and the wavefox tag below together.
    nixpkgs-firefox.url = "github:nixos/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";
    # Pinned to the release matching nixpkgs-firefox's Firefox major version.
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
        (import ./overlays/derivations.nix {
          hyprlandPluginsSrc = inputs.hyprland-plugins-src;
        })
        (final: prev: {
          inherit (inputs.nixpkgs-hyprland.legacyPackages.${prev.stdenv.hostPlatform.system})
            hyprland
            hyprlandPlugins
            xdg-desktop-portal-hyprland
            ;
        })
        (final: prev: {
          inherit (inputs.nixpkgs-firefox.legacyPackages.${prev.stdenv.hostPlatform.system})
            firefox
            ;
        })
      ];
      # extraSpecialArgs = {
      #   inherit inputs;
      #  secrets = import /secret/secrets.nix;
      #A };

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
          { home-manager.users.jesse = import ./users/jesse; }
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
