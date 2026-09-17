{
  coreutils,
  dbus,
  glib,
  hyprland,
  jq,
  lib,
  noctalia,
  socat,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "wallpaper-autopause";
  runtimeInputs = [
    coreutils
    dbus
    glib
    hyprland
    jq
    noctalia
    socat
    systemd
  ];
  text = builtins.readFile ./wallpaper-autopause.sh;
  meta = {
    description = "Pause Noctalia video wallpapers on occupied workspaces and the lock screen";
    platforms = lib.platforms.linux;
  };
}
