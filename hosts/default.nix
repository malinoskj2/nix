{ inputs, self, ... }:

let
  inherit (inputs)
    nixpkgs
    home-manager
    nix-index-database
    catppuccin
    ;

  common = {
    imports = [ home-manager.nixosModules.home-manager ];

    nixpkgs.config.allowUnfree = true;
    # modifications patches the pinned Hyprland plugin set, so it must come after pins.
    nixpkgs.overlays = with self.overlays; [
      inputs.apple-fonts.overlays.default
      pins
      modifications
    ];

    system.configurationRevision = self.rev or self.dirtyRev or null;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
      backupFileExtension = "hm-bak";
      sharedModules = [ catppuccin.homeModules.catppuccin ];
    };
  };

  mkHost =
    {
      modules,
      specialArgs ? { },
    }:
    nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
      }
      // specialArgs;
      modules = [ common ] ++ modules;
    };
in
{
  flake.nixosConfigurations = {
    home = mkHost {
      modules = [
        ./home/configuration.nix
        nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
        {
          home-manager.users.jesse.imports = [
            ../users/jesse
            ../users/jesse/desktop-home
          ];
        }
      ];
    };

    katana = mkHost {
      modules = [
        ./katana/configuration.nix
        { home-manager.users.jesse = import ../users/jesse; }
      ];
    };

    pi = mkHost {
      modules = [ ./pi/configuration.nix ];
    };

    media = mkHost {
      modules = [ ./media/configuration.nix ];
      specialArgs.secrets = import /secret/secrets.nix;
    };
  };
}
