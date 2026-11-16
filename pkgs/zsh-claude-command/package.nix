{
  claude-code,
  codex,
  coreutils,
  jq,
  lib,
  python3,
  replaceVarsWith,
  runCommand,
  zsh,
}:

replaceVarsWith {
  src = ./zsh-claude-command.plugin.zsh;
  dir = "share/zsh-claude-command";
  replacements = {
    claude = lib.getExe claude-code;
    codex = lib.getExe codex;
    jq = lib.getExe jq;
    mktemp = lib.getExe' coreutils "mktemp";
    rm = lib.getExe' coreutils "rm";
  };
  passthru.tests.widget =
    runCommand "zsh-claude-command-tests"
      {
        nativeBuildInputs = [
          coreutils
          jq
          python3
          zsh
        ];
        PLUGIN_TEMPLATE = ./zsh-claude-command.plugin.zsh;
      }
      ''
        python ${./tests/test_plugin.py}
        touch "$out"
      '';
  meta.description = "Turn natural-language requests into zsh commands with Claude Code or Codex";
}
