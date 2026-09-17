{ coreutils, writeShellApplication }:

writeShellApplication {
  name = "battery";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./battery.sh;
}
