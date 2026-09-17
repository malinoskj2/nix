# NVIDIA driver with NVENC for hardware transcoding inside containers.
{
  hardware = {
    nvidia-container-toolkit.enable = true;

    nvidia = {
      nvidiaPersistenced = true;

      # The proprietary kernel modules give the widest NVENC compatibility.
      open = false;
    };
  };

  # The nvidia module keys off this even without an X server.
  services.xserver.videoDrivers = [ "nvidia" ];
}
