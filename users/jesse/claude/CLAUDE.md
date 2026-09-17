# Global Claude Instructions

## Environment
- OS: NixOS with flakes
- Shell: zsh
- Nix config: `/home/jesse/nix/`

## Preferences
- Terse responses, no unnecessary explanation
- No trailing summaries after completing a task
- Prefer editing existing files over creating new ones
- No comments unless the why is non-obvious. Never write:
  - file headers or summaries describing what a file/module is
  - section labels or comments restating what the next line does
  - cross-reference pointers ("see docs/…", "see foo.nix")
  - comments explaining a change, task or history
