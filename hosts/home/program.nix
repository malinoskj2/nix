# Program
{ config, pkgs, ... }:

{
  programs.ssh.startAgent = true;
  programs.zsh.enable = true;
  programs.steam.enable = true;
  programs.gamemode.enable = true;
  programs.obs-studio = {
    enable = true;
    # cudaSupport adds the driver runpath to obs-nvenc-test; without it OBS hides NVENC.
    package = pkgs.obs-studio.override { cudaSupport = true; };
    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-pipewire-audio-capture
    ];
  };
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libcap
  ];
}
