{
  bash,
  coreutils,
  gawk,
  git,
  git-repo-guard,
  gnugrep,
  gnused,
  host-switch,
  lib,
  path,
  replaceVars,
  runCommand,
  rust-lints,
  util-linux,
  writeShellApplication,
}:

# git and nix come from the host's PATH, so the push goes through its git wrapper and
# Betterleaks hook, and nix matches the daemon. rust-lints only runs inside lint.nix's build.
writeShellApplication {
  name = "nix-land";
  runtimeInputs = [
    coreutils
    gawk
    git-repo-guard
    gnugrep
    gnused
    host-switch
    util-linux
  ];
  runtimeEnv.NIX_LAND_LINT = replaceVars ./lint.nix {
    nixpkgs = path;
    rustLints = rust-lints;
  };
  text = builtins.readFile ./nix-land.sh;
  passthru.tests.landing =
    runCommand "nix-land-tests"
      {
        nativeBuildInputs = [
          bash
          coreutils
          gawk
          git
          git-repo-guard
          gnugrep
          gnused
          util-linux
        ];
      }
      ''
        bash ${./test.sh} ${./nix-land.sh}
        touch "$out"
      '';
  meta = {
    description = "Merge a branch into the nix repository's main, check it, push it and switch home";
    platforms = lib.platforms.linux;
  };
}
