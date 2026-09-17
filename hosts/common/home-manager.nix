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
