{
  coreutils,
  findutils,
  jq,
  lib,
  util-linux,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-randomize";
  runtimeInputs = [
    coreutils
    findutils
    jq
    util-linux
  ];
  text = builtins.readFile ./wallpaper-randomize.sh;
  meta = {
    description = "Assign monitors random video wallpapers";
    platforms = lib.platforms.linux;
  };
}
