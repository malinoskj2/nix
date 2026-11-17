{
  lib,
  python3,
  unstable,
  writeShellApplication,
}:
writeShellApplication {
  name = "qwen-prompt";
  runtimeInputs = [
    python3
    unstable.opencode
    # This shared-model launcher targets home's RTX 5090. Avoid compiling
    # upstream's ten GPU architectures for a workstation-specific runtime.
    ((unstable.llama-cpp.override { cudaSupport = true; }).overrideAttrs (old: {
      cmakeFlags =
        builtins.filter (flag: !(lib.hasPrefix "-DCMAKE_CUDA_ARCHITECTURES" flag)) old.cmakeFlags
        ++ [ "-DCMAKE_CUDA_ARCHITECTURES=120" ];
    }))
  ];
  text = ''
    exec ${lib.getExe python3} ${./run.py} "$@"
  '';
  meta = {
    description = "Forward a prompt through scheduled local Qwen and OpenCode";
    platforms = [ "x86_64-linux" ];
  };
}
