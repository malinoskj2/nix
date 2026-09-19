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

## Task lists
- Each git repo has a shared task list, set by `env.CLAUDE_CODE_TASK_LIST_ID` in its `.claude/settings.local.json`.
- At the start of a session in a git repo, if that key is missing, set it to the basename of the main worktree (`basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`). Merge it into the existing file rather than overwriting it, and add `.claude/settings.local.json` to `.git/info/exclude` if Git doesn't already ignore it.
- The ID only applies from the next session, so tell me to restart when you add it.
