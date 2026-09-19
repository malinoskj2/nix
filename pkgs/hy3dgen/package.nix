{
  autoPatchelfHook,
  cudaPackages,
  fetchFromGitHub,
  fetchurl,
  lib,
  python3Packages,
  stdenv,
}:

let
  # torch-bin links libnvshmem, which nixpkgs builds from source for every CUDA arch plus tests and
  # examples, nearly exhausting RAM; build it for the RTX 5090 only. torch and torchvision alias the
  # wheels so accelerate, diffusers and the rest don't pull a second torch.
  pythonPackages = python3Packages.overrideScope (
    final: prev: {
      torch = final.torch-bin;
      torchvision = final.torchvision-bin;
      torch-bin = prev.torch-bin.override {
        cudaPackages = cudaPackages.overrideScope (
          _: prevCuda: {
            libnvshmem = prevCuda.libnvshmem.overrideAttrs (old: {
              cmakeFlags = old.cmakeFlags ++ [
                (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "120")
                (lib.cmakeBool "NVSHMEM_BUILD_TESTS" false)
                (lib.cmakeBool "NVSHMEM_BUILD_EXAMPLES" false)
              ];
            });
          }
        );
      };
    }
  );

  src = fetchFromGitHub {
    owner = "Tencent";
    repo = "Hunyuan3D-2";
    rev = "f8db63096c8282cb27354314d896feba5ba6ff8a";
    hash = "sha256-tbPuhnCqUcSnttdTs/DxcYLQWterNlbWyNqTHmUxcOs=";
  };

  # Upstream ships wheels only; the sdist needs the xatlas C++ tree as a submodule.
  xatlas = pythonPackages.buildPythonPackage rec {
    pname = "xatlas";
    version = "0.0.11";
    format = "wheel";

    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/85/84/df846c46097331af6a10d3675edefc2ab893cb784c02fc7ab1e8cc580457/xatlas-${version}-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
      hash = "sha256-HCulyl4m26XpoEqrmO5d4OWg6Mh6H+roPaEQUrg9ht0=";
    };

    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    dependencies = [ pythonPackages.numpy ];

    pythonImportsCheck = [ "xatlas" ];
  };

  # nvcc needs a host compiler it supports, older than the default stdenv's.
  buildCudaPythonPackage = python3Packages.buildPythonPackage.override {
    stdenv = cudaPackages.backendStdenv;
  };

  custom-rasterizer = buildCudaPythonPackage {
    pname = "custom-rasterizer";
    version = "0.1";
    pyproject = true;

    inherit src;
    sourceRoot = "${src.name}/hy3dgen/texgen/custom_rasterizer";

    build-system = [ pythonPackages.setuptools ];

    nativeBuildInputs = [ (lib.getBin cudaPackages.cuda_nvcc) ];
    buildInputs = with cudaPackages; [
      cuda_cccl
      cuda_cudart
      libcublas
      libcusolver
      libcusparse
    ];

    dependencies = with pythonPackages; [
      numpy
      opencv4
      pillow
      pygltflib
      scipy
      torch-bin
    ];

    # RTX 5090 (Blackwell) only.
    env = {
      TORCH_CUDA_ARCH_LIST = "12.0";
      # torch's gcc bounds table stops at 13 for CUDA 12.9, though nvcc 12.9 supports gcc 14.
      TORCH_DONT_CHECK_COMPILER_ABI = "1";
    };

    preBuild = ''
      export MAX_JOBS="$NIX_BUILD_CORES"
    '';

    pythonImportsCheck = [ "custom_rasterizer" ];
  };
in
pythonPackages.buildPythonPackage {
  pname = "hy3dgen";
  version = "2.0.2-unstable-2025-10-28";
  pyproject = true;

  inherit src;

  build-system = [ pythonPackages.setuptools ];

  nativeBuildInputs = [ pythonPackages.pybind11 ];

  # gradio, fastapi and uvicorn only serve the demo; ninja and pybind11 only build the extensions.
  pythonRemoveDeps = [
    "gradio"
    "fastapi"
    "uvicorn"
    "ninja"
    "pybind11"
    "opencv-python"
    # nixpkgs' pymeshlab installs no dist-info, so the metadata check can't find it; it's still a dependency below.
    "pymeshlab"
  ];

  dependencies =
    with pythonPackages;
    [
      accelerate
      diffusers
      einops
      huggingface-hub
      numpy
      omegaconf
      onnxruntime
      opencv4
      pillow
      pygltflib
      pymeshlab
      pyyaml
      rembg
      safetensors
      scikit-image
      scipy
      torch-bin
      torchvision-bin
      tqdm
      transformers
      trimesh
    ]
    ++ [
      custom-rasterizer
      xatlas
    ];

  # diffusers >= 0.36 refuses local custom pipelines without trust_remote_code.
  postPatch = ''
    substituteInPlace hy3dgen/texgen/utils/multiview_utils.py \
      --replace-fail "torch_dtype=torch.float16)" "torch_dtype=torch.float16, trust_remote_code=True)"
  '';

  # mesh_processor.so shadows the pure-Python fallback next to it.
  postInstall = ''
    (cd hy3dgen/texgen/differentiable_renderer && python setup.py build_ext --inplace)
    cp hy3dgen/texgen/differentiable_renderer/mesh_processor*.so \
      "$out/${pythonPackages.python.sitePackages}/hy3dgen/texgen/differentiable_renderer/"
  '';

  pythonImportsCheck = [
    "hy3dgen.shapegen"
    "hy3dgen.texgen"
    "hy3dgen.texgen.differentiable_renderer.mesh_processor"
  ];

  meta = {
    description = "Hunyuan3D 2.0 image-to-3D shape and texture generation";
    homepage = "https://github.com/Tencent/Hunyuan3D-2";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
}
