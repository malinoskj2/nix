{ pkgs }:
let
  # The hosts install claude-code, codex and noctalia from pkgs.unstable; wrappers use those builds.
  callPackage = pkgs.newScope { inherit (pkgs.unstable) claude-code codex noctalia; };

  # Built-ins only: the overlay passes its final pkgs, so the names can't depend on pkgs.lib.
  directories = builtins.removeAttrs (builtins.readDir ./.) [ "default.nix" ];
in
builtins.mapAttrs (name: _: callPackage ./${name}/package.nix { }) directories
