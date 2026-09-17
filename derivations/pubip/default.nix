{ curl, writeShellApplication }:

writeShellApplication {
  name = "pubip";
  runtimeInputs = [ curl ];
  text = builtins.readFile ./pubip.sh;
}
