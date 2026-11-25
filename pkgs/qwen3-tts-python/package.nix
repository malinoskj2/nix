{
  autoPatchelfHook,
  fetchPypi,
  fetchurl,
  hy3dgen,
  stdenv,
}:

let
  # Reuses hy3dgen's CUDA torch-bin, so the GPU stack is the one the sandbox already builds.
  pythonPackages = hy3dgen.pythonPackages.overrideScope (
    final: _prev: {
      # faster-qwen3-tts needs transformers >= 5.15.1, whose import-time check wants safetensors >= 0.8.
      safetensors = final.buildPythonPackage rec {
        pname = "safetensors";
        version = "0.8.0";
        format = "wheel";
        src = fetchurl {
          url = "https://files.pythonhosted.org/packages/28/50/f203ff3a3ddfe19308efc83c5a3a29ed02bf786732ec35e68bf9162f3365/safetensors-${version}-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
          hash = "sha256-/W8/k8mgp8wniO5j+3YzU9S9LomwdRvHj8992gC+p3Q=";
        };
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [ stdenv.cc.cc.lib ];
        pythonImportsCheck = [ "safetensors" ];
      };

      transformers = final.buildPythonPackage rec {
        pname = "transformers";
        version = "5.15.1";
        format = "wheel";
        src = fetchurl {
          url = "https://files.pythonhosted.org/packages/41/c4/a12e1d9b387fb0c40a57116db82b457e8c771cb419163cda29204d74a595/transformers-${version}-py3-none-any.whl";
          hash = "sha256-t83yOP9YPjpY28f6NNoarwkc4GMUH2WjBTgWC9Wv6T8=";
        };
        dependencies = with final; [
          huggingface-hub
          numpy
          packaging
          pyyaml
          regex
          safetensors
          tokenizers
          tqdm
          typer
        ];
      };

      sox = final.buildPythonPackage rec {
        pname = "sox";
        version = "1.5.0";
        pyproject = true;
        src = fetchPypi {
          inherit pname version;
          hash = "sha256-Ese+W7H1SNiR/hHoLAjPXxoddOIlKY9gCC5a6yRpraA=";
        };
        build-system = [ final.setuptools ];
        dependencies = with final; [
          numpy
          typing-extensions
        ];
        pythonImportsCheck = [ "sox" ];
      };

      qwen-tts-hf = final.buildPythonPackage rec {
        pname = "qwen-tts-hf";
        version = "0.1.1.post1";
        format = "wheel";
        src = fetchurl {
          url = "https://files.pythonhosted.org/packages/ed/14/57e0ba0b84535102e08f33f1e14a2e0975229f5b878290343705727a3a33/qwen_tts_hf-${version}-py3-none-any.whl";
          hash = "sha256-7Vt6rmTPeVJDNp+1ImFz9FmkVonqhtscbT6xT8DCwB0=";
        };
        # Only the demo uses gradio.
        pythonRemoveDeps = [ "gradio" ];
        pythonRelaxDeps = [ "accelerate" ];
        dependencies = with final; [
          accelerate
          einops
          librosa
          onnxruntime
          soundfile
          sox
          torch-bin
          torchaudio-bin
          transformers
        ];
      };

      faster-qwen3-tts = final.buildPythonPackage rec {
        pname = "faster-qwen3-tts";
        version = "0.5.4";
        format = "wheel";
        src = fetchurl {
          url = "https://files.pythonhosted.org/packages/b3/e5/074b3ca7bb05f2d3564a456bc7620c24e65edeb1288c118a4b0506d55f11/faster_qwen3_tts-${version}-py3-none-any.whl";
          hash = "sha256-cUv7bQpw+sF36sSLCnUOBL1ZermqhtNcQnGqFdDRtxY=";
        };
        dependencies = with final; [
          huggingface-hub
          numpy
          qwen-tts-hf
          soundfile
          torch-bin
          transformers
        ];
      };
    }
  );

  python = pythonPackages.python.withPackages (_: [
    pythonPackages.faster-qwen3-tts
    pythonPackages.numpy
    pythonPackages.torch-bin
  ]);
in
python.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit pythonPackages;
  };
  meta = (old.meta or { }) // {
    description = "Python with CUDA torch and faster-qwen3-tts, for Tohru's high-VRAM voice";
    platforms = [ "x86_64-linux" ];
  };
})
