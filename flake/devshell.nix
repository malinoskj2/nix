{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      # Editors call the formatters directly, and ruff-check and ruff-format share one package.
      formatters = lib.unique (lib.attrValues config.treefmt.build.programs);
      # The newest CUDA that home's NVIDIA driver supports (nvidia-smi's CUDA version).
      cuda = pkgs.unstable.cudaPackages_13_4;
    in
    {
      devShells = {
        default = pkgs.mkShellNoCC {
          packages = [
            config.treefmt.build.wrapper
            pkgs.nh
            pkgs.nixd
            pkgs.nvd
          ]
          ++ formatters;
        };
      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        # nvcc's profile already names CUDA's supported host compiler. cudarc loads the driver and
        # the toolkit's libraries at runtime, and candle builds its kernels for CUDA_COMPUTE_CAP.
        cuda = pkgs.mkShell {
          packages = [ cuda.cudatoolkit ];
          CUDA_PATH = cuda.cudatoolkit;
          CUDA_ROOT = cuda.cudatoolkit;
          CUDA_TOOLKIT_ROOT_DIR = cuda.cudatoolkit;
          CUDA_COMPUTE_CAP = "120";
          LD_LIBRARY_PATH = "/run/opengl-driver/lib:${cuda.cudatoolkit}/lib";
        };
      };
    };
}
