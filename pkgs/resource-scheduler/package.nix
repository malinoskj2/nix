{
  lib,
  python3,
  runCommand,
  symlinkJoin,
  writeShellScriptBin,
  slurm,
  docker,
  util-linux,
  coreutils,
}:
let
  source = runCommand "resource-scheduler-source" { } ''
    mkdir -p "$out"
    substitute ${./resource_scheduler.py} "$out/resource_scheduler.py" \
      --replace-fail '@resourceToolPath@' '${
        lib.makeBinPath [
          slurm
          docker
          util-linux
          coreutils
        ]
      }:/run/opengl-driver/bin:/run/current-system/sw/bin'
  '';
  command =
    name: action:
    writeShellScriptBin name ''
      exec ${lib.getExe python3} -I ${source}/resource_scheduler.py ${action} "$@"
    '';
in
symlinkJoin {
  name = "resource-scheduler";
  paths = [
    (command "resource-run" "run")
    (command "resource-status" "status")
    (command "resource-control" "control")
    (command "resource-model" "model")
    (command "resource-scheduler" "")
  ];
  passthru.tests.scheduler =
    runCommand "resource-scheduler-tests" { nativeBuildInputs = [ python3 ]; }
      ''
        cp ${./resource_scheduler.py} resource_scheduler.py
        cp ${./test_resource_scheduler.py} test_resource_scheduler.py
        python -m unittest -v
        touch "$out"
      '';
  meta = {
    description = "Slurm-backed host and sandbox resource admission, controls and telemetry";
    platforms = lib.platforms.linux;
  };
}
