{
  coreutils,
  dbus,
  glib,
  hyprland,
  jq,
  noctalia,
  socat,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-autopause";
  runtimeInputs = [
    noctalia
    coreutils
    dbus
    glib
    hyprland
    jq
    socat
    systemd
  ];
  text = builtins.readFile ./wallpaper-autopause.sh;
}
