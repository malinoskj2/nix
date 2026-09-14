{ pkgs, ... }:
{
  imports = [ ../../modules/nixos/fonts.nix ];

  fonts.packages = with pkgs; [ nerd-fonts.droid-sans-mono ];
}
