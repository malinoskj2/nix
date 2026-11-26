{
  cargo,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  host-switch,
  lib,
  rust-lints,
  util-linux,
  writeShellApplication,
}:

# git and nix come from the host's PATH, so the push goes through its git wrapper and
# Betterleaks hook, and nix matches the daemon.
writeShellApplication {
  name = "nix-land";
  runtimeInputs = [
    cargo
    coreutils
    gawk
    gnugrep
    gnused
    host-switch
    rust-lints
    util-linux
  ];
  text = builtins.readFile ./nix-land.sh;
  meta = {
    description = "Merge a branch into the nix repository's main, check it, push it and switch home";
    platforms = lib.platforms.linux;
  };
}
