{
  description = ":)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    utils.url = "github:gytis-ivaskevicius/flake-utils-plus";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
      home-manager,
      ...
    }@inputs:
    utils.lib.mkFlake {
      inherit self inputs;

      channelsConfig.allowUnfree = true;
      sharedOverlays = [ (import ./overlays/derivations.nix) ];
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
        }
      ];

      hosts.home = {
        system = "x86_64-linux";
        modules = [
          ./hosts/home/configuration.nix
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
