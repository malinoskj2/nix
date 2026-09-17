{
  claude-code,
  codex,
  coreutils,
  lib,
  replaceVarsWith,
}:

replaceVarsWith {
  src = ./zsh-claude-command.plugin.zsh;
  dir = "share/zsh-claude-command";
  replacements = {
    claude = lib.getExe claude-code;
    codex = lib.getExe codex;
    mktemp = lib.getExe' coreutils "mktemp";
    rm = lib.getExe' coreutils "rm";
  };
  meta.description = "Zsh widget that turns a `# request` line into a command via Claude Code or Codex";
}
