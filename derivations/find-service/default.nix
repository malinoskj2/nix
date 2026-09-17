{
  gawk,
  gnused,
  nmap,
  writeShellApplication,
}:

writeShellApplication {
  name = "find-service";
  runtimeInputs = [
    gawk
    gnused
    nmap
  ];
  text = builtins.readFile ./find-service.sh;
}
