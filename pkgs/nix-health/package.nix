{
  coreutils,
  gawk,
  jq,
  lib,
  main-checkout-report,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "nix-health";
  runtimeInputs = [
    coreutils
    gawk
    jq
    main-checkout-report
    systemd
  ];
  text = builtins.readFile ./nix-health.sh;
  meta = {
    description = "Report failed units, low disk, stuck Orca workers, stale workspaces and dirty main checkouts";
    platforms = lib.platforms.linux;
  };
}
