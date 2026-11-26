{
  lib,
  fetchFromGitHub,
  cudaPackages_13_0,
  cmake,
  ninja,
  python3,
  makeWrapper,
}:
let
  # Strata's setup pins CUDA 13.0: 13.2 miscompiles its kernels for sm_120.
  cudaPackages = cudaPackages_13_0;
  python = python3.withPackages (
    ps: with ps; [
      numpy
      jinja2
      regex
      pyyaml
      tqdm
      requests
      pillow
      psutil
    ]
  );
in
cudaPackages.backendStdenv.mkDerivation (_finalAttrs: {
  pname = "strata";
  version = "0.2.22";

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "b28ca95e3e6847f2d5e317994f253b66716deeaa";
    hash = "sha256-NgirO05es3iS5ya4cJfK/PqUzlLJOhllQ6XYQvzG/0k=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    makeWrapper
    python3
    cudaPackages.cuda_nvcc
  ];
  buildInputs = with cudaPackages; [
    cuda_cudart
    cuda_cccl
    libcublas
  ];

  cmakeDir = "../engine";
  # The home RTX 5090 only; the release build's AVX2 baseline instead of the build machine's ISA.
  cmakeFlags = [
    (lib.cmakeBool "STRATA_ENABLE_CUDA" true)
    (lib.cmakeBool "STRATA_BUILD_TESTS" false)
    (lib.cmakeBool "STRATA_NATIVE_EXPERTS" true)
    (lib.cmakeBool "STRATA_Q6K_EXPERTS" true)
    (lib.cmakeBool "STRATA_PORTABLE" true)
    (lib.cmakeBool "STRATA_BUILD_INKLING" false)
    (lib.cmakeBool "STRATA_BUILD_INKLING2" false)
    (lib.cmakeBool "GGML_CCACHE" false)
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "120")
  ];

  ninjaFlags = [ "strata" ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/strata
    install -m755 strata $out/bin/strata
    cp -r ../terminal ../tools $out/share/strata/
    makeWrapper ${python.interpreter} $out/bin/strata-server \
      --add-flags "$out/share/strata/terminal/serve/server.py" \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    makeWrapper ${python.interpreter} $out/bin/strata-tokenizer \
      --add-flags "$out/share/strata/terminal/tools/strata_tokenizer.py"
    licenses=$out/share/licenses/strata
    install -Dm644 ../LICENSE $licenses/LICENSE
    for dir in ../engine/third_party/*/; do
      name=$(basename "$dir")
      for file in "$dir"LICENSE* "$dir"NOTICE* "$dir"COPYING*; do
        if [ -f "$file" ]; then
          install -Dm644 "$file" "$licenses/third_party/$name/$(basename "$file")"
        fi
      done
      if [ -d "$dir"licenses ]; then
        cp -r "$dir"licenses "$licenses/third_party/$name/"
      fi
    done
    cp -r ../tools/packaging/notices $licenses/notices
    runHook postInstall
  '';

  passthru = { inherit python; };

  meta = {
    description = "Strata: MoE inference engine that keeps experts and KV cache it can't fit in VRAM in system RAM";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
})
