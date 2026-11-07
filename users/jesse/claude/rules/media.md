# Images and videos

- Save every screenshot, screen recording and other development image or video in `.tmp/` at the root of the current repository or worktree (create it if missing). Resolve that root with `git rev-parse --show-toplevel`; `.tmp/` is globally Git-ignored.
- Give me each file's absolute path on the host. In the agent sandbox, keep the repository or worktree under a shared project directory so its `.tmp/` files are available at the same host paths.
