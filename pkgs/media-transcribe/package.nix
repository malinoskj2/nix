{
  ctranslate2,
  lib,
  python3,
  runCommand,
  stdenv,
  writeShellScriptBin,
}:
let
  cudaSupport = stdenv.hostPlatform.isx86_64;
  engine = (ctranslate2.override { withCUDA = cudaSupport; }).overrideAttrs (old: {
    # FindCUDA's legacy architecture parser rejects Blackwell's two-digit major version.
    postPatch =
      (old.postPatch or "")
      + lib.optionalString cudaSupport ''
        substituteInPlace CMakeLists.txt \
          --replace-fail 'cuda_select_nvcc_arch_flags(ARCH_FLAGS ''${CUDA_ARCH_LIST})' \
          'set(ARCH_FLAGS "-gencode=arch=compute_120,code=sm_120" "-gencode=arch=compute_120,code=compute_120")'
      '';
  });
  python = python3.withPackages (ps: [
    (ps.faster-whisper.override {
      ctranslate2 = ps.ctranslate2.override { ctranslate2-cpp = engine; };
    })
  ]);
in
(writeShellScriptBin "media-transcribe" ''
  exec ${lib.getExe python} ${./transcribe.py} "$@"
'').overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      tests.transcribe = runCommand "media-transcribe-tests" { nativeBuildInputs = [ python3 ]; } ''
        cp ${./transcribe.py} transcribe.py
        cp ${./test_transcribe.py} test_transcribe.py
        python -B -m unittest -v
        touch "$out"
      '';
    };
    meta = {
      description = "On-demand local audio transcription with faster-whisper";
      mainProgram = "media-transcribe";
      platforms = lib.platforms.linux;
    };
  })
