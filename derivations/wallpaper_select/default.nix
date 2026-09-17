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
  name = "wallpaper_select";
  runtimeInputs = [
    noctalia
    coreutils
    findutils
    hyprland
    jq
    socat
  ];
  text = builtins.readFile ./wallpaper_select.sh;
}
