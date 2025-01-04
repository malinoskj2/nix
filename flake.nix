{
  description = ":)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    utils.url = "github:gytis-ivaskevicius/flake-utils-plus";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, utils, home-manager, ... }@inputs:
    utils.lib.mkFlake {
      inherit self inputs;

      channelsConfig.allowUnfree = true;

      sharedOverlays = [ (import ./overlays/derivations.nix) ];
      extraSpecialArgs = { 
	inherit inputs; 
	secrets = import /secret/secrets.nix;
      };

      hostDefaults.modules = [
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
        }
      ];

      hosts.home = {
        system = "x86_64-linux";
        modules = [
          ./hosts/home/configuration.nix
          { home-manager.users.jesse = import ./users/jesse; }
        ];
	specialArgs = { secrets = import /secret/secrets.nix; };
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
    };
}
