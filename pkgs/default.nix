# Defines the local packages that overlays.additions and perSystem.packages expose.
{ pkgs }:
let
  # The hosts install claude-code, codex and noctalia from pkgs.unstable; wrappers use those builds.
  callPackage = pkgs.newScope { inherit (pkgs.unstable) claude-code codex noctalia; };
in
{
  ai-usage = callPackage ./ai-usage/package.nix { };
  ata-devs = callPackage ./ata-devs/package.nix { };
  battery = callPackage ./battery/package.nix { };
  find-service = callPackage ./find-service/package.nix { };
  git-commitu = callPackage ./git-commitu/package.nix { };
  git-open-branch = callPackage ./git-open-branch/package.nix { };
  htop-vim-navigation = callPackage ./htop-vim-navigation/package.nix { };
  pubip = callPackage ./pubip/package.nix { };
  wallpaper-autopause = callPackage ./wallpaper-autopause/package.nix { };
  wallpaper-randomize = callPackage ./wallpaper-randomize/package.nix { };
  wallpaper-select = callPackage ./wallpaper-select/package.nix { };
  wifi-connect = callPackage ./wifi-connect/package.nix { };
  zsh-claude-command = callPackage ./zsh-claude-command/package.nix { };
}
