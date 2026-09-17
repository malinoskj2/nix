# Home Manager settings shared by NixOS and nix-darwin. Importers add the platform's module.
{ inputs, ... }:
{
  home-manager = {
    backupFileExtension = "hm-bak";
    extraSpecialArgs = { inherit inputs; };
    sharedModules = [ inputs.catppuccin.homeModules.catppuccin ];
    useGlobalPkgs = true;
    useUserPackages = true;
  };
}
