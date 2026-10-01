{
  hyprland,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "hyprland-quit";
  runtimeInputs = [ hyprland ];
  text = ''
    : "''${HYPRLAND_INSTANCE_SIGNATURE:?Run hyprland-quit inside the Hyprland session you want to end.}"
    exec hyprctl -i "$HYPRLAND_INSTANCE_SIGNATURE" eval 'hl.dispatch(hl.dsp.exit())'
  '';
  meta = {
    description = "Exit the current Hyprland session";
    platforms = lib.platforms.linux;
  };
}
