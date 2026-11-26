{
  coreutils,
  git,
  gnugrep,
  gnused,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "main-checkout-report";
  runtimeInputs = [
    coreutils
    git
    gnugrep
    gnused
    jq
  ];
  text = builtins.readFile ./main-checkout-report.sh;
  meta.description = "List Orca projects' main checkouts that are dirty or off their default branch";
}
