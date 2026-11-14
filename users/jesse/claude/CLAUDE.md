# Global Claude Instructions

## Environment
- OS: NixOS with flakes
- Shell: zsh
- Nix config: `/home/jesse/nix/`

## Preferences
- Terse responses, no unnecessary explanation
- No trailing summaries after completing a task
- Prefer editing existing files over creating new ones
- Don't run long-running benchmarks unless I explicitly ask or the task is specifically about performance
- No comments unless the why is non-obvious. Never write:
  - file headers or summaries describing what a file/module is
  - section labels or comments restating what the next line does
  - cross-reference pointers ("see docs/…", "see foo.nix")
  - comments explaining a change, task or history

## Subagents
- Never use Fable for subagents, workflow agents or non-leader agent-team members unless I explicitly ask for Fable. Pick another model instead, even if an agent definition or skill would default to Fable.
