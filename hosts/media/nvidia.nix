# NVIDIA — RTX 3060 Ti (Ampere) for NVENC hardware transcode inside containers.
{ config, pkgs, ... }:

{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware = {
    graphics.enable = true;
    nvidia = {
      open = false;
      modesetting.enable = true;
      nvidiaPersistenced = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
    nvidia-container-toolkit.enable = true;
  };
  environment.systemPackages = with pkgs; [ nvtopPackages.nvidia ];
}
