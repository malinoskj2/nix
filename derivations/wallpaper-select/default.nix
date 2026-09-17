{
  coreutils,
  findutils,
  hyprland,
  jq,
  noctalia,
  socat,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-select";
  runtimeInputs = [
    noctalia
    coreutils
    findutils
    hyprland
    jq
    socat
  ];
  text = builtins.readFile ./wallpaper-select.sh;
}
