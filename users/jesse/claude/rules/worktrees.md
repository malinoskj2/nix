# Worktrees

- When work needs worktrees, such as parallel variations, create them with your own tooling (the Agent tool's worktree isolation, or `git worktree add`), not Orca.
- Create Orca worktrees (`orca worktree create`) only when I ask for Orca. This overrides the orca-cli skill's preference for Orca over raw git worktrees.
- When closing out or removing a worktree, check whether it is managed by Orca. If it is, use the Orca workflow to close out the corresponding Orca worktree as well. The restriction on creating Orca worktrees does not restrict cleaning up existing ones.
- Scope cleanup to the worktree requested. If I explicitly identify a worktree, close out only that one; do not close other worktrees or sessions. Resolve “this worktree” to the current task's worktree, not every worktree in the repository.
