{ pkgs, ... }:
{
  programs.obs-studio = {
    enable = true;

    # cudaSupport adds the driver runpath to obs-nvenc-test; without it, OBS hides NVENC.
    package = pkgs.obs-studio.override { cudaSupport = true; };

    plugins = with pkgs.obs-studio-plugins; [
      obs-pipewire-audio-capture
      wlrobs
    ];
  };
}
