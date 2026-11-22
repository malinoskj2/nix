{
  applyPatches,
  cudaPackages,
  fetchFromGitHub,
  hy3dgen,
  lib,
  makeWrapper,
  stdenvNoCC,
}:

let
  pythonPackages = hy3dgen.pythonPackages.overrideScope (
    final: prev: {
      # torch-bin brings its own triton; a second one fails the closure conflict check.
      triton = final.triton-bin;
      # Needs Inductor's C compiler, which the build sandbox lacks.
      timm = prev.timm.overridePythonAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [ "test_kron" ];
      });
    }
  );

  cudaOverrides = {
    cudaSupport = true;
    buildPythonPackage = pythonPackages.buildPythonPackage.override {
      stdenv = cudaPackages.backendStdenv;
    };
  };

  buildThreads = 6;

  # The daemon's core count applies to untrusted clients, so the cap lives in the builds.
  capThreads =
    pkg:
    pkg.overridePythonAttrs (old: {
      preConfigure = ''
        export NIX_BUILD_CORES=${toString buildThreads}
      ''
      + (old.preConfigure or "");
      env = (old.env or { }) // {
        MAX_JOBS = toString buildThreads;
        CUPY_NUM_BUILD_JOBS = toString buildThreads;
      };
    });

  # Each upstream builds kernels for a fixed list that lacks the RTX 5090's sm_120.
  onlySm120 =
    pkg:
    pkg.overridePythonAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        ${pythonPackages.python.interpreter} - <<'EOF'
        import re
        source = open("setup.py").read()
        source, count = re.subn(
            r'\n(\s*)cc_flag\.append\("-gencode"\)\n\s*cc_flag\.append\("arch=[^"]+"\)', r"\n\1pass", source
        )
        assert count, "no gencode flags"
        source = source.replace("cc_flag = []", 'cc_flag = ["-gencode", "arch=compute_120,code=sm_120"]', 1)
        source = source.replace('["--threads", "4"]', '["--threads", "1"]')
        open("setup.py", "w").write(source)
        EOF
      '';
      env = (old.env or { }) // {
        TORCH_DONT_CHECK_COMPILER_ABI = "1";
        CAUSAL_CONV1D_FORCE_BUILD = "TRUE";
        MAMBA_FORCE_BUILD = "TRUE";
      };
    });

  causal-conv1d = capThreads (onlySm120 (pythonPackages.causal-conv1d.override cudaOverrides));
  mamba-ssm =
    (capThreads (
      onlySm120 (pythonPackages.mamba-ssm.override (cudaOverrides // { inherit causal-conv1d; }))
    )).overridePythonAttrs
      (old: {
        # transformers 5 merged the greedy and sample outputs into one class.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace mamba_ssm/utils/generation.py --replace-fail \
            "GreedySearchDecoderOnlyOutput, SampleDecoderOnlyOutput, TextStreamer" \
            "GenerateDecoderOnlyOutput as GreedySearchDecoderOnlyOutput, GenerateDecoderOnlyOutput as SampleDecoderOnlyOutput, TextStreamer"
        '';
      });
  cupy = capThreads pythonPackages.cupy;

  python = pythonPackages.python.withPackages (
    _ps:
    [
      hy3dgen
      causal-conv1d
      cupy
      mamba-ssm
    ]
    ++ (with pythonPackages; [
      av
      einops
      ftfy
      imageio
      imageio-ffmpeg
      kornia
      omegaconf
      open-clip-torch
      opencv4
      packaging
      pandas
      pytorch-lightning
      pyyaml
      safetensors
      scipy
      timm
    ])
  );

  # cupy compiles its kernels at run time.
  nvrtc = "${lib.getLib cudaPackages.cuda_nvrtc}/lib";

  comfyui-frame-interpolation = fetchFromGitHub {
    owner = "Fannovel16";
    repo = "ComfyUI-Frame-Interpolation";
    rev = "26545cc2dd95bc3d27f056016300673bdeee78f5";
    hash = "sha256-Xtgh9dh+EPhOQpsq9MPaoJsJPBkFBlBKetwGgY441f0=";
  };
  ema-vfi = fetchFromGitHub {
    owner = "MCG-NJU";
    repo = "EMA-VFI";
    rev = "75b6f6a889e695df875e103374040d47a4cfac7c";
    hash = "sha256-86n3WWdpPtjAA/buNwyqfBHjIvc65JCWGa2SC1m7VHM=";
  };
  vfimamba = fetchFromGitHub {
    owner = "MCG-NJU";
    repo = "VFIMamba";
    rev = "8df805eb054cd423e188d509210731cffe9438af";
    hash = "sha256-olY4ij2xISM/hiXk2UHz/giEPpyKWRBQWSCqGnCIQR4=";
  };
  tooncrafter = applyPatches {
    name = "tooncrafter-source";
    src = fetchFromGitHub {
      owner = "Doubiiu";
      repo = "ToonCrafter";
      rev = "b0c47ff339c5e5ec45b84d0c6587850f242d41ef";
      hash = "sha256-A14R4RuoLIMjSpV5/CoZfv/Zo4Lkp+GVljN9Il9mqTw=";
    };
    patches = [
      # open_clip 3 removed dual patchnorm and runs its attention blocks batch-first.
      ./tooncrafter-open-clip-3.patch
    ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "frame-interpolation";
  version = "0-unstable-2026-11-18";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    share=$out/share/frame-interpolation
    mkdir -p $share $out/bin
    cp -r ${comfyui-frame-interpolation} $share/comfyui-frame-interpolation
    cp -r ${ema-vfi} $share/ema-vfi
    cp -r ${vfimamba} $share/vfimamba
    cp -r ${tooncrafter} $share/tooncrafter
    chmod -R u+w $share

    # The nodes only need ComfyUI's device helpers.
    mkdir $share/comfyui-frame-interpolation/comfy
    touch $share/comfyui-frame-interpolation/comfy/__init__.py
    cat > $share/comfyui-frame-interpolation/comfy/model_management.py <<'EOF'
    import torch


    def get_torch_device():
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")


    def soft_empty_cache():
        if torch.cuda.is_available():
            torch.cuda.empty_cache()


    def is_nvidia():
        return torch.cuda.is_available() and torch.version.cuda is not None


    def get_torch_device_name(device):
        return torch.cuda.get_device_name(device) if device.type == "cuda" else str(device)
    EOF
    substituteInPlace $share/comfyui-frame-interpolation/vfi_utils.py \
      --replace-fail 'os.path.dirname(__file__), config["ckpts_path"], model_type' \
        'os.environ["FRAME_INTERP_CKPTS"], model_type'

    # The Lightning checkpoint holds more than tensors; it is the pinned official file.
    substituteInPlace $share/tooncrafter/scripts/evaluation/inference.py \
      --replace-fail 'torch.load(ckpt, map_location="cpu")' 'torch.load(ckpt, map_location="cpu", weights_only=False)'
    substituteInPlace $share/tooncrafter/lvdm/modules/encoders/condition.py \
      --replace-fail 'pretrained=version)' 'pretrained=os.environ.get("TOONCRAFTER_OPENCLIP", version))' \
      --replace-fail 'pretrained=version, )' 'pretrained=os.environ.get("TOONCRAFTER_OPENCLIP", version), )'
    sed -i '1i import os' $share/tooncrafter/lvdm/modules/encoders/condition.py

    cp ${./frame_interp.py} $share/frame_interp.py
    makeWrapper ${python.interpreter} $out/bin/frame-interp \
      --add-flags $share/frame_interp.py \
      --set FRAME_INTERP_SHARE $share \
      --prefix LD_LIBRARY_PATH : ${nvrtc}

    makeWrapper ${python.interpreter} $out/bin/tooncrafter \
      --prefix LD_LIBRARY_PATH : ${nvrtc} \
      --add-flags "$share/tooncrafter/scripts/evaluation/inference.py" \
      --run 'models=''${MODEL_ROOT:-/home/jesse/.local/share/models}/by-name' \
      --run 'export TOONCRAFTER_OPENCLIP=''${TOONCRAFTER_OPENCLIP:-$models/openclip-vit-h-14/open_clip_model.safetensors}' \
      --add-flags '--ckpt_path "$models/tooncrafter/model.ckpt"' \
      --add-flags "--config $share/tooncrafter/configs/inference_512_v1.0.yaml" \
      --add-flags '--n_samples 1 --bs 1 --height 320 --width 512 --unconditional_guidance_scale 7.5' \
      --add-flags '--ddim_steps 50 --ddim_eta 1.0 --text_input --video_length 16 --frame_stride 10' \
      --add-flags "--timestep_spacing uniform_trailing --guidance_rescale 0.7 --perframe_ae --interp"

    makeWrapper ${python.interpreter} $out/bin/frame-interp-python \
      --prefix LD_LIBRARY_PATH : ${nvrtc}
    runHook postInstall
  '';

  passthru = { inherit python; };

  meta = {
    description = "Frame interpolation runtimes: RIFE, GMFSS Fortuna, FILM, EMA-VFI, VFIMamba, ToonCrafter and Wan FLF2V";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "frame-interp";
  };
}
