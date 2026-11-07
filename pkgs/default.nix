{ pkgs }:
let
  # The hosts install agent CLIs from pkgs.unstable; wrappers use those builds.
  callPackage = pkgs.newScope {
    inherit (pkgs.unstable)
      claude-code
      codex
      ;
  };

  # Built-ins only: the overlay passes its final pkgs, so the names can't depend on pkgs.lib.
  entries = builtins.readDir ./.;
  packages = builtins.filter (
    name: entries.${name} == "directory" && builtins.pathExists ./${name}/package.nix
  ) (builtins.attrNames entries);
in
builtins.listToAttrs (
  builtins.map (name: {
    inherit name;
    value = callPackage ./${name}/package.nix { };
  }) packages
)
