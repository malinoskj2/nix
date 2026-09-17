{ git, writeShellApplication }:

writeShellApplication {
  name = "git-commitu";
  runtimeInputs = [ git ];
  text = builtins.readFile ./git-commitu.sh;
  meta.description = "Run git commit with GPG signing disabled";
}
