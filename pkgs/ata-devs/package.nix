{
  coreutils,
  gnugrep,
  gnused,
  lib,
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
  meta = {
    description = "Map ATA error port names to block devices";
    platforms = lib.platforms.linux;
  };
}
