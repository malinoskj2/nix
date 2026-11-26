{
  lib,
  python3,
  runCommand,
  symlinkJoin,
  unstable,
  writeShellApplication,
}:
let
  source = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py") ./.;
  };
  # This shared-model launcher targets home's RTX 5090. Avoid compiling
  # upstream's ten GPU architectures for a workstation-specific runtime.
  llama-cpp = (unstable.llama-cpp.override { cudaSupport = true; }).overrideAttrs (old: {
    cmakeFlags =
      builtins.filter (flag: !(lib.hasPrefix "-DCMAKE_CUDA_ARCHITECTURES" flag)) old.cmakeFlags
      ++ [ "-DCMAKE_CUDA_ARCHITECTURES=120" ];
  });
  command =
    name: script:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        python3
        unstable.opencode
        llama-cpp
      ];
      text = ''
        exec ${lib.getExe python3} ${source}/${script} "$@"
      '';
    };
in
symlinkJoin {
  name = "qwen-prompt";
  paths = [
    (command "qwen-prompt" "run.py")
    (command "qwen-opencode" "opencode.py")
  ];
  passthru.tests.launchers =
    runCommand "qwen-prompt-tests"
      {
        nativeBuildInputs = [ python3 ];
      }
      ''
        cp ${source}/*.py .
        python -m unittest -v test_run test_launcher test_opencode
        touch "$out"
      '';
  meta = {
    description = "Scheduled local Qwen through OpenCode: one-shot prompts and an idle-unloading interactive session";
    platforms = [ "x86_64-linux" ];
  };
}
