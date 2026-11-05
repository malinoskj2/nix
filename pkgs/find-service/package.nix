{
  gawk,
  lib,
  nmap,
  writeShellApplication,
}:

writeShellApplication {
  name = "find-service";
  runtimeInputs = [
    gawk
    nmap
  ];
  text = builtins.readFile ./find-service.sh;
  meta = {
    description = "Find hosts on the LAN serving a known service port";
    platforms = lib.platforms.linux;
  };
}
