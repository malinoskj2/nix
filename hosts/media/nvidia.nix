# NVIDIA — RTX 3060 Ti (Ampere) for NVENC hardware transcode inside containers.
{ config, pkgs, ... }:

{
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  hardware.nvidia-container-toolkit.enable = true;
  environment.systemPackages = with pkgs; [ nvtopPackages.nvidia ];
}
