{
  coreutils,
  findutils,
  git,
  gnused,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "target-sweep";
  runtimeInputs = [
    coreutils
    findutils
    git
    gnused
    jq
  ];
  text = builtins.readFile ./target-sweep.sh;
  meta.description = "Remove Cargo target directories of Orca worktrees idle for two weeks";
}
