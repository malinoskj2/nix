{ pkgs }:
let
  # The hosts install agent CLIs from pkgs.unstable; wrappers use those builds.
  callPackage = pkgs.newScope {
    inherit (pkgs.unstable)
      claude-code
      codex
      opencode
      ;
    inherit j2bar;
  };

  # TODO: replace this stand-in with the j2bar package once the flake has it. Noctalia takes the
  # same `msg status` and `dmenu -p`, so the wallpaper scripts keep working while it is the shell.
  j2bar = pkgs.writeShellScriptBin "j2bar" ''
    exec ${pkgs.lib.getExe pkgs.unstable.noctalia} "$@"
  '';

  # Built-ins only: the overlay passes its final pkgs, so the names can't depend on pkgs.lib.
  directories = builtins.removeAttrs (builtins.readDir ./.) [ "default.nix" ];
in
builtins.mapAttrs (name: _: callPackage ./${name}/package.nix { }) directories
