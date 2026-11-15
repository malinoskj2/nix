{
  lib,
  python3,
  runCommand,
  symlinkJoin,
  writeShellScriptBin,
  unifiedScheduler ? null,
}:
let
  command =
    name: action:
    writeShellScriptBin name ''
      if [ -f /etc/resource-scheduler/mode ] && [ "$(cat /etc/resource-scheduler/mode)" = slurm ]; then
        ${
          if unifiedScheduler == null then
            ''
              echo 'gpu-scheduler: Slurm authority selected but compatibility client is unavailable; rebuild this client' >&2
              exit 1
            ''
          else
            ''
              exec ${unifiedScheduler}/bin/resource-scheduler compat ${action} "$@"
            ''
        }
      fi
      export PATH="$PATH:/run/opengl-driver/bin:/usr/bin"
      exec ${lib.getExe python3} ${./gpu_scheduler.py} ${action} "$@"
    '';
in
symlinkJoin {
  name = "gpu-scheduler";
  paths = [
    (command "gpu-run" "run")
    (command "gpu-game" "game")
    (command "gpu-status" "status")
    (command "gpu-scheduler-telemetry" "serve-telemetry")
  ];
  passthru.tests.scheduler =
    runCommand "gpu-scheduler-tests"
      {
        nativeBuildInputs = [ python3 ];
      }
      ''
        cp ${./gpu_scheduler.py} gpu_scheduler.py
        cp ${./test_gpu_scheduler.py} test_gpu_scheduler.py
        python -m unittest -v
        touch "$out"
      '';
  meta = {
    description = "Coordinate shared VRAM reservations and exclusive GPU workloads across host and sandboxes";
    platforms = lib.platforms.linux;
  };
}
