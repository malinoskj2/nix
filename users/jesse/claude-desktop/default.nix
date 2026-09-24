{ config, pkgs, ... }:
{
  home.packages = [
    (pkgs.claude-desktop.override {
      theme = pkgs.callPackage ./theme.nix { inherit (config) palette; };
    })
  ];
}
