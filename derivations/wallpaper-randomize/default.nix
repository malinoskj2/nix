{
  coreutils,
  findutils,
  jq,
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
}
