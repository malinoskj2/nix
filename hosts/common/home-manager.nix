# Home Manager settings for NixOS and nix-darwin hosts; each host also imports
# its platform's Home Manager module.
{ inputs, ... }:
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "hm-bak";
    sharedModules = [ inputs.catppuccin.homeModules.catppuccin ];
  };
}
