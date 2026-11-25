# Pushing

- Push with plain `git push`, never through `gh`: not `gh pr create --push`, `gh repo create --push`, `gh repo sync` or `gh api` writes to a repository's contents or refs. Push the branch with git first, then use `gh` only for the pull request or other metadata.
- Every push runs a Betterleaks scan of the pushed commits. When it refuses a push, remove the secret from those commits (amend or rebase) and push again. A suspected false positive goes to the human.
- Never pass `--no-verify` to `git push`, set `BETTERLEAKS_PUSH_BYPASS`, disable the `betterleaks-push-gate` hook or call another git to get around the scan. The bypass is the human's alone.
