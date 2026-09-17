{ curl, writeShellApplication }:

writeShellApplication {
  name = "pubip";
  runtimeInputs = [ curl ];
  text = builtins.readFile ./pubip.sh;
  meta.description = "Print the public IP address";
}
