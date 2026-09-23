---
paths:
  - "**/Cargo.toml"
  - "**/*.rs"
---

# Cargo

Debug builds of larger projects run to tens of GB per target dir, so share one per repository.

- Build every worktree, branch and subagent of a repository into the main worktree's target dir. From a linked worktree, export `CARGO_TARGET_DIR="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/target"` unless the project already sets `build.target-dir`. Don't create other target dirs.
- Dependencies built there are reused across worktrees, and each worktree's own crates get separate artifacts, so builds don't overwrite each other. A second build waits on the dir's lock (`Blocking waiting for file lock`); that isn't a hang.
- `target/<profile>/<bin>` is whichever worktree built last. Launch binaries with `cargo run`, not by that path.
- Never `cargo clean` a shared target dir. Delete only target dirs you created, once you're done with them.
