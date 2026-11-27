{
  bash,
  coreutils,
  git,
  lib,
  runCommand,
  writeShellApplication,
}:

let
  guard = writeShellApplication {
    name = "git-repo-guard";
    runtimeInputs = [
      coreutils
      git
    ];
    text = builtins.readFile ./git-repo-guard.sh;
    passthru.tests.guard =
      runCommand "git-repo-guard-tests"
        {
          nativeBuildInputs = [
            bash
            coreutils
            git
            guard
          ];
        }
        ''
          export HOME=$PWD
          bash ${./test.sh}
          touch "$out"
        '';
    meta = {
      description = "Refuse a Git repository whose config or hooks would run programs";
      platforms = lib.platforms.linux;
    };
  };
in
guard
