# The local package set, exposed as overlays.additions and perSystem.packages.
{ pkgs }:
{
  ai-usage = pkgs.callPackage ./ai-usage/package.nix { };
  ata-devs = pkgs.callPackage ./ata-devs/package.nix { };
  battery = pkgs.callPackage ./battery/package.nix { };
  find-service = pkgs.callPackage ./find-service/package.nix { };
  git-commitu = pkgs.callPackage ./git-commitu/package.nix { };
  # Installs `git-open`; nixpkgs already has an unrelated package by that name.
  git-open-branch = pkgs.callPackage ./git-open-branch/package.nix { };
  htop-vim-navigation = pkgs.callPackage ./htop-vim-navigation/package.nix { };
  pubip = pkgs.callPackage ./pubip/package.nix { };
  wallpaper-autopause = pkgs.callPackage ./wallpaper-autopause/package.nix {
    inherit (pkgs.unstable) noctalia;
  };
  wallpaper-randomize = pkgs.callPackage ./wallpaper-randomize/package.nix { };
  wallpaper-select = pkgs.callPackage ./wallpaper-select/package.nix {
    inherit (pkgs.unstable) noctalia;
  };
  wifi-connect = pkgs.callPackage ./wifi-connect/package.nix { };
  zsh-claude-command = pkgs.callPackage ./zsh-claude-command/package.nix {
    inherit (pkgs.unstable) claude-code codex;
  };
}
