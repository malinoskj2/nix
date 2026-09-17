# Program
{ pkgs, ... }:

{
  programs = {
    steam.enable = true;
    gamemode.enable = true;
    obs-studio = {
      enable = true;
      # cudaSupport adds the driver runpath to obs-nvenc-test; without it OBS hides NVENC.
      package = pkgs.obs-studio.override { cudaSupport = true; };
      plugins = with pkgs.obs-studio-plugins; [
        wlrobs
        obs-pipewire-audio-capture
      ];
    };
  };
}
