{
  coreutils,
  findutils,
  hyprland,
  jq,
  lib,
  socat,
  util-linux,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-select";
  runtimeInputs = [
    coreutils
    findutils
    hyprland
    jq
    socat
    util-linux
  ];
  text = builtins.readFile ./wallpaper-select.sh;
  meta = {
    description = "Pick a monitor's video wallpaper";
    platforms = lib.platforms.linux;
  };
}
