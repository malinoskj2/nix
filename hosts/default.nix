{ inputs, self, ... }:

let
  inherit (inputs)
    nixpkgs
    home-manager
    catppuccin
    ;

  common =
    { config, ... }:
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
      ];

      system.configurationRevision = self.rev or self.dirtyRev or null;

      programs.nh = {
        enable = true;
        flake = "/home/jesse/nix";
        # media keeps its own nix.gc schedule.
        clean.enable = !config.nix.gc.automatic;
        clean.extraArgs = "--keep-since 7d --keep 5";
      };

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
}
