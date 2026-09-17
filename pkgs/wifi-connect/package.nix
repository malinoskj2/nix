{
  coreutils,
  dhcpcd,
  gawk,
  gnugrep,
  iproute2,
  iw,
  lib,
  procps,
  util-linux,
  wpa_supplicant,
  writeShellApplication,
}:

writeShellApplication {
  name = "wifi-connect";
  runtimeInputs = [
    coreutils
    dhcpcd
    gawk
    gnugrep
    iproute2
    iw
    procps
    util-linux
    wpa_supplicant
  ];
  text = builtins.readFile ./wifi-connect.sh;
  meta = {
    description = "Scan for and join a wifi network imperatively";
    platforms = lib.platforms.linux;
  };
}
