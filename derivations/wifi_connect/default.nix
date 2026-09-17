{
  coreutils,
  dhcpcd,
  gawk,
  gnugrep,
  iproute2,
  iw,
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
  text = builtins.readFile ./wifi_connect.sh;
}
