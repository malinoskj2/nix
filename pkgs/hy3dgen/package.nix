{
  autoPatchelfHook,
  cudaPackages,
  fetchFromGitHub,
  fetchPypi,
  lib,
  python3Packages,
  stdenv,
}:

let
  src = fetchFromGitHub {
    owner = "Tencent";
    repo = "Hunyuan3D-2";
    rev = "f8db63096c8282cb27354314d896feba5ba6ff8a";
    hash = "sha256-tbPuhnCqUcSnttdTs/DxcYLQWterNlbWyNqTHmUxcOs=";
  };

  # Upstream ships wheels only; the sdist needs the xatlas C++ tree as a submodule.
  xatlas = python3Packages.buildPythonPackage rec {
    pname = "xatlas";
    version = "0.0.11";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      python = "cp313";
      abi = "cp313";
      platform = "manylinux_2_17_x86_64.manylinux2014_x86_64";
      hash = "sha256-HCulyl4m26XpoEqrmO5d4OWg6Mh6H+roPaEQUrg9ht0=";
    };

    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    dependencies = [ python3Packages.numpy ];

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

    build-system = [ python3Packages.setuptools ];

    nativeBuildInputs = [ (lib.getBin cudaPackages.cuda_nvcc) ];
    buildInputs = with cudaPackages; [
      cuda_cccl
      cuda_cudart
    ];

    dependencies = with python3Packages; [
      numpy
      pillow
      pygltflib
      scipy
      torch-bin
    ];

    # RTX 5090 (Blackwell) only.
    env.TORCH_CUDA_ARCH_LIST = "12.0";

    preBuild = ''
      export MAX_JOBS="$NIX_BUILD_CORES"
    '';

    pythonImportsCheck = [ "custom_rasterizer" ];
  };
in
python3Packages.buildPythonPackage {
  pname = "hy3dgen";
  version = "2.0.2-unstable-2025-10-28";
  pyproject = true;

  inherit src;

  build-system = [ python3Packages.setuptools ];

  nativeBuildInputs = [ python3Packages.pybind11 ];

  # gradio, fastapi and uvicorn only serve the demo; ninja and pybind11 only build the extensions.
  pythonRemoveDeps = [
    "gradio"
    "fastapi"
    "uvicorn"
    "ninja"
    "pybind11"
    "opencv-python"
  ];

  dependencies =
    with python3Packages;
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
      "$out/${python3Packages.python.sitePackages}/hy3dgen/texgen/differentiable_renderer/"
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
