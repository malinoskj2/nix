{ git, writeShellApplication }:

writeShellApplication {
  name = "git-commitu";
  runtimeInputs = [ git ];
  text = builtins.readFile ./git-commitu.sh;
}
