{
  git,
  gnused,
  lib,
  stdenv,
  writeShellApplication,
  xdg-utils,
}:

writeShellApplication {
  name = "git-open";
  runtimeInputs = [
    git
    gnused
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ xdg-utils ];
  text = builtins.readFile ./git-open-branch.sh;
  meta.description = "Open the origin remote's web page for the current branch";
}
