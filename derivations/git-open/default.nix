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
  text = builtins.readFile ./git-open.sh;
}
