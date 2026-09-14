# Audio — shared PipeWire baseline for desktop hosts (home, katana).
_: {
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Text to Speech
  services.speechd.enable = false;
}
