{
  gawk,
  gnused,
  nmap,
  writeShellApplication,
}:

writeShellApplication {
  name = "find_service";
  runtimeInputs = [
    gawk
    gnused
    nmap
  ];
  text = builtins.readFile ./find_service.sh;
}
