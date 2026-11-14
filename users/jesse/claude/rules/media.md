# Images and videos

- Save every screenshot, screen recording and other development image or video in `.tmp/` at the root of the current repository or worktree (create it if missing). Resolve that root with `git rev-parse --show-toplevel`; `.tmp/` is globally Git-ignored.
- When showing me three or more images or videos at once, or asking me to look at or choose between media, present them with `media-gallery` (see its skill), with anything that needs my decision under Needs review. I reply in chat by `#id`.
- Give me each file's absolute path on the host. In the agent sandbox, keep the repository or worktree under a shared project directory so its `.tmp/` files are available at the same host paths.

## Asset storage

- Keep assets actively used by the current task or application on the host. Archive old assets that are no longer actively used to `/mnt/media3/agent/$REPO_NAME/`, including inactive assets in `.tmp/` and other output directories. Use the main repository's name for `REPO_NAME`, not a linked worktree's name; derive it from the parent of `git rev-parse --path-format=absolute --git-common-dir` for a normal or linked checkout.
- Preserve original files and their relative directory structure, separating task or worktree outputs where needed to avoid collisions. Never overwrite a different archived file. Leave a small local index at `.tmp/asset-archive.md` recording original locations and absolute archive paths so future sessions can retrieve them.
- Verify that the destination is on the mounted NFS share before writing. Copy with `rsync`, verify the destination against the source with checksums, and remove local copies only after verification succeeds. If the share is unavailable or a copy or verification fails, keep the local files and report it; never create a local fallback under the mount path.
- When an archived asset is needed again, copy it back to local working storage before using it and keep the archived copy. Assets referenced by the application, builds or current work remain active; don't move tracked assets or break existing references.
