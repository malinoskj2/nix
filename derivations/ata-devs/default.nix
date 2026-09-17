{
  coreutils,
  gnugrep,
  gnused,
  writeShellApplication,
}:

writeShellApplication {
  name = "ata-devs";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
  ];
  text = builtins.readFile ./ata-devs.sh;
}
