{
  coreutils,
  dbus,
  glib,
  hyprland,
  j2bar,
  jq,
  lib,
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
    j2bar
    jq
    socat
    systemd
  ];
  text = builtins.readFile ./wallpaper-autopause.sh;
  meta = {
    description = "Pause video wallpapers on occupied workspaces and the lock screen";
    platforms = lib.platforms.linux;
  };
}
