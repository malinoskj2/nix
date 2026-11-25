{
  coreutils,
  diffutils,
  findutils,
  git,
  gnugrep,
  gnused,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "worktree-closeout";
  runtimeInputs = [
    coreutils
    diffutils
    findutils
    git
    gnugrep
    gnused
    jq
  ];
  text = builtins.readFile ./worktree-closeout.sh;
  meta.description = "Preserve a merged Orca worktree's .tmp and untracked files, then remove it";
}
