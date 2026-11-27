{
  git,
  lib,
  openssl,
  python3,
  runCommand,
  symlinkJoin,
  unstable,
  writeShellApplication,
}:
let
  inherit (unstable) betterleaks;

  server = writeShellApplication {
    name = "agent-push";
    runtimeInputs = [
      betterleaks
      git
      openssl
    ];
    text = ''exec ${lib.getExe python3} -I ${./push.py} "$@"'';
  };

  client = writeShellApplication {
    name = "sandbox-push";
    runtimeInputs = [ git ];
    text = ''exec ${lib.getExe python3} -I ${./sandbox-push.py} "$@"'';
  };
in
symlinkJoin {
  name = "agent-push";
  paths = [
    server
    client
  ];
  passthru = {
    inherit client;
    tests.push =
      runCommand "agent-push-tests"
        {
          nativeBuildInputs = [
            betterleaks
            git
            openssl
            python3
          ];
        }
        ''
          cp ${./push.py} push.py
          cp ${./sandbox-push.py} sandbox-push.py
          cp ${./test_push.py} test_push.py
          HOME=$TMPDIR python -B test_push.py -v
          touch "$out"
        '';
  };
  meta = {
    description = "Push gateway that pushes sandbox branches to GitHub with short-lived GitHub App tokens";
    platforms = lib.platforms.linux;
    mainProgram = "sandbox-push";
  };
}
