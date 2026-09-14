# X11
{
  config,
  pkgs,
  lib,
  ...
}:
{
  # The nvidia module keys off this even without an X server.
  services.xserver.videoDrivers = [ "nvidia" ];
}
