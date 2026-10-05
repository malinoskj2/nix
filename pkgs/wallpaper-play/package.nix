{
  coreutils,
  jq,
  lib,
  mpvpaper,
  wallpaper-randomize,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-play";
  runtimeInputs = [
    coreutils
    jq
    mpvpaper
    wallpaper-randomize
  ];
  text = builtins.readFile ./wallpaper-play.sh;
  meta = {
    description = "Play a monitor's assigned video as its wallpaper";
    platforms = lib.platforms.linux;
  };
}
