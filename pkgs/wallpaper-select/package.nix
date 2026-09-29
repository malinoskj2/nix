{
  coreutils,
  findutils,
  hyprland,
  jq,
  lib,
  noctalia,
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
    noctalia
    socat
    util-linux
  ];
  text = builtins.readFile ./wallpaper-select.sh;
  meta = {
    description = "Pick a monitor's video wallpaper";
    platforms = lib.platforms.linux;
  };
}
