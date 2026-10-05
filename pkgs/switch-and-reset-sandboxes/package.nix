{
  coreutils,
  docker,
  gawk,
  lib,
  nh,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "switch-and-reset-sandboxes";
  runtimeInputs = [
    coreutils
    docker
    gawk
    nh
    systemd
  ];
  text = builtins.readFile ./switch-and-reset-sandboxes.sh;
  meta = {
    description = "Rebuild NixOS with an optional reset of active agent sandboxes";
    platforms = lib.platforms.linux;
  };
}
