{
  coreutils,
  findutils,
  hyprland,
  jq,
  lib,
  noctalia,
  socat,
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
  ];
  text = builtins.readFile ./wallpaper-select.sh;
  meta = {
    description = "Pick a Noctalia video wallpaper for a monitor";
    platforms = lib.platforms.linux;
  };
}
