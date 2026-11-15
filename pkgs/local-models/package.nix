{
  lib,
  python3,
  coreutils,
  curl,
  runCommand,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [
    ps.huggingface-hub
    ps.pyarrow
  ]);
  package = writeShellApplication {
    name = "local-models";
    runtimeInputs = [
      coreutils
      curl
    ];
    text = ''
      exec ${lib.getExe python} ${./local_models.py} "$@"
    '';
    meta = {
      description = "Pinned host model storage, synchronization and readiness";
      mainProgram = "local-models";
      platforms = lib.platforms.linux;
    };
  };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests.sync =
      runCommand "local-models-tests"
        {
          nativeBuildInputs = [
            python
            coreutils
          ];
        }
        ''
          cp ${./local_models.py} local_models.py
          cp ${./test_local_models.py} test_local_models.py
          python -B -m unittest -v
          touch "$out"
        '';
  };
})
