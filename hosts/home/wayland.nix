# Wayland
{
  pkgs,
  config,
  ...
}:

{
  programs.hyprland.enable = true;

  # The nvidia module keys off this even without an X server.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware = {
    graphics = {
      enable32Bit = true;
      extraPackages = with pkgs; [ nvidia-vaapi-driver ];
    };
    nvidia = {
      # Newer than 26.05's 595.71.05; hashes from nixos-unstable's production driver.
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "595.99.02";
        sha256_64bit = "sha256-6HR3lYv3YwcFSTJL1a1slI66btIQ5EAFs+/4SUD24ew=";
        sha256_aarch64 = "sha256-CCqHZTN2KNOZ4yZp2rDcuRJp9pHfRw47k4m4dWnS/2w=";
        openSha256 = "sha256-T36x/jx8yQ8l3LFp1rZIrTfcSwbGy8YSAvXOUSptpb4=";
        settingsSha256 = "sha256-GYCcnxfKPrTCrsmd25sMyzfC5cqJQJx0c31haooyTYM=";
        persistencedSha256 = "sha256-VyKtF/HdHPQrHHK6opSO69M72LmnGZtauuchj9uuje8=";
      };
      modesetting.enable = true;
      open = true;
      nvidiaSettings = false;
      powerManagement.enable = true;
    };
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    MOZ_DISABLE_RDD_SANDBOX = "1";
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };
}
