{
  coreutils,
  gnugrep,
  gnused,
  writeShellApplication,
}:

writeShellApplication {
  name = "ata_devs";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
  ];
  text = builtins.readFile ./ata_devs.sh;
}
