{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "ai-usage";
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = builtins.readFile ./ai-usage.sh;
  meta.description = "Show remaining Claude Code and Codex usage limits";
}
