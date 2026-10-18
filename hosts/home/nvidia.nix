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
        version = "615.78.08";
        sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
        sha256_aarch64 = "sha256-UHYBE1AYHoGgMfD9AS/jX+S+N8eCDWUft6qolK9Eejc=";
        openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
        settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
        persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
      };
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
