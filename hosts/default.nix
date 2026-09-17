{ inputs, self, ... }:

let
  inherit (inputs)
    nixpkgs
    nix-darwin
    home-manager
    catppuccin
    ;

  commonNixos =
    { config, pkgs, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      nixpkgs.config.allowUnfree = true;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      # modifications patches the pinned Hyprland plugin set, so it must come after pins.
      nixpkgs.overlays = with self.overlays; [
        inputs.apple-fonts.overlays.default
        unstable
        pins
        modifications
        htopVimNavigation
      ];

      system.configurationRevision = self.rev or self.dirtyRev or null;

      programs.nh = {
        enable = true;
        flake = "/home/jesse/nix";
        # The media host sets its own nix.gc schedule in its misc module.
        clean.enable = !config.nix.gc.automatic;
        clean.extraArgs = "--keep-since 7d --keep 5";
      };

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit inputs pkgs; };
        backupFileExtension = "hm-bak";
        sharedModules = [ catppuccin.homeModules.catppuccin ];
      };
    };

  commonDarwin =
    { pkgs, ... }:
    {
      imports = [ home-manager.darwinModules.home-manager ];

      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = with self.overlays; [
        unstable
        htopVimNavigation
      ];

      system.configurationRevision = self.rev or self.dirtyRev or null;

      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit inputs pkgs; };
        backupFileExtension = "hm-bak";
        sharedModules = [ catppuccin.homeModules.catppuccin ];
      };
    };

  mkHost =
    { modules }:
    nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [ commonNixos ] ++ modules;
    };

  mkDarwinHost =
    { modules }:
    nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs; };
      modules = [ commonDarwin ] ++ modules;
    };
in
{
  perSystem =
    { pkgs, ... }:
    {
      formatter = pkgs.nixfmt-tree;

      checks = {
        # hardware-configuration.nix files are machine-generated; keep them generated
        # rather than hand-editing them to satisfy the linters.
        statix = pkgs.runCommand "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
          cd ${self}
          statix check . --ignore 'hosts/*/hardware-configuration.nix'
          touch $out
        '';

        deadnix =
          pkgs.runCommand "deadnix-check"
            {
              nativeBuildInputs = [ pkgs.deadnix ];
            }
            ''
              deadnix --fail ${self} --exclude ${self}/hosts/home/hardware-configuration.nix ${self}/hosts/katana/hardware-configuration.nix ${self}/hosts/media/hardware-configuration.nix
              touch $out
            '';
      }
      // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        macbook = self.darwinConfigurations.macbook.system;
      };
    };

  flake.nixosConfigurations = {
    home = mkHost {
      modules = [ ./home/configuration.nix ];
    };

    katana = mkHost {
      modules = [ ./katana/configuration.nix ];
    };

    pi = mkHost {
      modules = [ ./pi/configuration.nix ];
    };

    media = mkHost {
      modules = [ ./media/configuration.nix ];
    };
  };

  flake.darwinConfigurations.macbook = mkDarwinHost {
    modules = [ ./macbook/configuration.nix ];
  };
}
