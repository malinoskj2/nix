# Worktrees

- When work needs worktrees, such as parallel variations, create them with your own tooling (the Agent tool's worktree isolation, or `git worktree add`), not Orca.
- Create Orca worktrees (`orca worktree create`) only when I ask for Orca. This overrides the orca-cli skill's preference for Orca over raw git worktrees.
