# NVIDIA — RTX 3060 Ti (Ampere) for NVENC hardware transcode inside containers.
{ config, pkgs, ... }:

{
  # Userspace GL/compute/video libraries (renamed from hardware.opengl in 24.11).
  hardware.graphics.enable = true;

  # Selects and loads the NVIDIA kernel driver even on a headless box. Does not
  # start X — nothing else here enables a display server.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Proprietary kernel modules — widest NVENC/userspace compatibility.
    # Ampere also runs the open modules (open = true) if you prefer those.
    open = false;

    modesetting.enable = true;

    # Keep the GPU initialized without an X server or active client: cuts
    # per-transcode init latency and stops the card idling down on a headless
    # host.
    nvidiaPersistenced = true;

    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Generates the CDI spec and wires the NVIDIA runtime into Docker so a
  # container can claim the GPU. Replaces the deprecated
  # virtualisation.docker.enableNvidia.
  hardware.nvidia-container-toolkit.enable = true;

  # nvidia-smi ships with the driver; nvtop for live transcode/GPU monitoring.
  environment.systemPackages = with pkgs; [ nvtopPackages.nvidia ];
}
