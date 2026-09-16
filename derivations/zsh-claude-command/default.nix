{
  claude-code,
  codex,
  coreutils,
  lib,
  writeTextDir,
}:

writeTextDir "share/zsh-claude-command/zsh-claude-command.plugin.zsh" (
  builtins.replaceStrings
    [ "@claude@" "@codex@" "@mktemp@" "@rm@" ]
    [
      (lib.getExe claude-code)
      (lib.getExe codex)
      (lib.getExe' coreutils "mktemp")
      (lib.getExe' coreutils "rm")
    ]
    (builtins.readFile ./zsh-claude-command.plugin.zsh)
)
