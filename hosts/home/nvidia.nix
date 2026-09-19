{ config, pkgs, ... }:
{
  hardware = {
    graphics = {
      enable32Bit = true;
      extraPackages = [ pkgs.nvidia-vaapi-driver ];
    };
    nvidia-container-toolkit.enable = true;
    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "615.71.09";
        sha256_64bit = "sha256-zc7tIrvrYSSNGm3qvCWWZz46ZQFpjucayNL9wo87cP4=";
        sha256_aarch64 = "sha256-IbekQhE7cFfmnPZaLY9NDYcF7CoNZ+2Qb7sRd4EOgWM=";
        openSha256 = "sha256-3gByMYIwFzRaLdDG+roCEOuKRRJDrljG9AlLnRZTirM=";
        settingsSha256 = "sha256-LK1LU8mDkM/XVRKPBtuOZh9nIP/lGFLAJnmasEX8jhg=";
        persistencedSha256 = "sha256-qPRb+3d88+2RcpUkoBTbjIaImnQ+jX+/6p1vXcJ5geE=";
      };
      modesetting.enable = true;
      nvidiaSettings = false;
      open = true;
      powerManagement.enable = true;
    };
  };

  # The nvidia module keys off this even without an X server.
  services.xserver.videoDrivers = [ "nvidia" ];

  environment.sessionVariables = {
    GBM_BACKEND = "nvidia-drm";
    LIBVA_DRIVER_NAME = "nvidia";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";

    # Firefox's RDD sandbox blocks NVIDIA VA-API decoding.
    MOZ_DISABLE_RDD_SANDBOX = "1";

    # nvidia-vaapi-driver's EGL backend doesn't work with current drivers.
    NVD_BACKEND = "direct";
  };
}
