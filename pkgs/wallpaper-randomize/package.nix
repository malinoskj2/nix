{
  coreutils,
  findutils,
  jq,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-randomize";
  runtimeInputs = [
    coreutils
    findutils
    jq
  ];
  text = builtins.readFile ./wallpaper-randomize.sh;
  meta = {
    description = "Assign each monitor a random Noctalia video wallpaper";
    platforms = lib.platforms.linux;
  };
}
