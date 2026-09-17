# NVENC hardware transcoding inside containers.
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware = {
    nvidia = {
      open = false;
      nvidiaPersistenced = true;
    };
    nvidia-container-toolkit.enable = true;
  };
}
