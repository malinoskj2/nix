# Secret scan on push

Every `git push` from the Home Manager hosts (`home`, `katana`, `mac-vm`) and
from the agent sandbox runs [Betterleaks](https://github.com/betterleaks/betterleaks),
the successor to gitleaks, over the commits being pushed. If it finds a secret,
or can't run, the push is refused.

## How it works

[`users/jesse/git.nix`](../users/jesse/git.nix) registers a config-based hook
(Git 2.54's `hook.<name>.event`) in the global git config:

```ini
[hook "betterleaks-push-gate"]
  event = pre-push
  command = /nix/store/…-betterleaks-pre-push/bin/betterleaks-pre-push
```

Config hooks run before the repository's own hook, so a repository's
`.git/hooks/pre-push`, or one under its `core.hooksPath` (Husky, pre-commit),
still runs afterwards and gets the same refs on stdin. `core.hooksPath` doesn't
turn the scan off. The agent sandbox mounts `~/.config/git` read-only and shares
`/nix/store`, so the same hook applies there.

For each ref the push updates, the hook
([`pkgs/betterleaks-push-gate/pre-push.sh`](../pkgs/betterleaks-push-gate/pre-push.sh))
scans:

- an update: the commits between the remote's old commit and the new one;
- a new branch or tag, or a force push over a commit you don't have: the new
  commit's history, minus what the remote's tracking branches already contain.
  A first push to an empty remote, or a push to a bare URL, scans the whole
  history;
- a deletion: nothing.

A finding prints the rule, file and commit with the secret redacted. Remove
the secret from those commits (amend or rebase, and rotate it if it was real),
then push again. A false positive can go in a `.betterleaksignore` (or
`.gitleaksignore`) fingerprint list at the repository root. Repository
`.betterleaks.toml` configs aren't loaded.

The hook runs Betterleaks by its store path. If that path is missing, git can't
start the hook and refuses the push.

## `--no-verify`

`git push --no-verify` skips every pre-push hook. The `git` on `PATH` is a thin
wrapper ([`git.sh`](../pkgs/betterleaks-push-gate/git.sh)) that refuses
`push --no-verify`, and its abbreviations, before git runs. `git commit
--no-verify` and every other command pass straight through.

## Emergency bypass

```sh
BETTERLEAKS_PUSH_BYPASS="<reason>" git push
```

The scan is skipped, the repository's own pre-push hook still runs, and a line
with the time, user, host, remote, refs and reason is appended to
`.git/betterleaks-push-bypass.log` in that repository (the common git
directory, for a worktree). If that log can't be written, the push is
refused. Agents are told never to use it.

## GitHub CLI

`gh` pushes commits by running `git push` from `PATH`, so `gh pr create --push`,
`gh repo create --push` and `gh skills publish` go through the hook. Some
commands write to a repository through the API instead, which no local hook
sees. The `gh` on `PATH` is a wrapper ([`gh.sh`](../pkgs/betterleaks-push-gate/gh.sh))
that refuses them:

- `gh repo sync`, whose remote mode moves a fork's branch through the
  merge-upstream and git refs APIs;
- `gh api` writes (any method but `GET` and `HEAD`) to `git/blobs`,
  `git/trees`, `git/commits`, `git/tags`, `git/refs`, `contents/` and
  `merge-upstream`;
- `gh api graphql` with a `createCommitOnBranch` mutation, or with a query on
  stdin that the wrapper can't read.

Push with git and use `gh` for the pull request. The wrapper doesn't cover
gists, release assets, `gh codespace cp`, extensions or `gh` aliases that
expand to the refused commands.

## Limits

This is a guardrail against accidents, not a security boundary. Calling git or
`gh` by store path, a git older than 2.54, `-c hook.betterleaks-push-gate.command=…`
or a git alias for `push --no-verify` all get around it. Betterleaks reads
commit diffs, so a secret that only appears in a merge commit's conflict
resolution isn't seen.

For public repositories, also turn on GitHub's secret scanning push protection
(Settings → Advanced Security → Secret Protection and Push protection), which
GitHub checks server-side on every push, including API writes.
