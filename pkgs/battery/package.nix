{
  coreutils,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "battery";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./battery.sh;
  meta = {
    description = "Print the laptop battery's charge and status";
    platforms = lib.platforms.linux;
  };
}
