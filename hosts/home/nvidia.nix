{ config, pkgs, ... }:
{
  hardware = {
    graphics = {
      enable32Bit = true;
      extraPackages = [ pkgs.nvidia-vaapi-driver ];
    };
    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "595.99.02";
        sha256_64bit = "sha256-6HR3lYv3YwcFSTJL1a1slI66btIQ5EAFs+/4SUD24ew=";
        sha256_aarch64 = "sha256-CCqHZTN2KNOZ4yZp2rDcuRJp9pHfRw47k4m4dWnS/2w=";
        openSha256 = "sha256-T36x/jx8yQ8l3LFp1rZIrTfcSwbGy8YSAvXOUSptpb4=";
        settingsSha256 = "sha256-GYCcnxfKPrTCrsmd25sMyzfC5cqJQJx0c31haooyTYM=";
        persistencedSha256 = "sha256-VyKtF/HdHPQrHHK6opSO69M72LmnGZtauuchj9uuje8=";
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
