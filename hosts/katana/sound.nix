{ config, pkgs, ... }:

{
  # Sound
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Text to Speech
  services.speechd.enable = false;
  services.orca.enable = false;

  # Fix for pipewire-pulse breaking recently
  systemd.user.services.pipewire-pulse.path = [ pkgs.pulseaudio ];
}

