{
  coreutils,
  hyprland,
  jq,
  lib,
  socat,
  systemd,
  wallpaper-randomize,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-outputs";
  runtimeInputs = [
    coreutils
    hyprland
    jq
    socat
    systemd
    wallpaper-randomize
  ];
  text = builtins.readFile ./wallpaper-outputs.sh;
  meta = {
    description = "Run a video wallpaper on every connected monitor";
    platforms = lib.platforms.linux;
  };
}
