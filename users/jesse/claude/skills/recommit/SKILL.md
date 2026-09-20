---
name: recommit
description: Rebuild the current branch's commits into a clean, reviewable sequence on a new branch, verifying each commit independently. Never pushes. Use when the user invokes $recommit or /recommit, or asks to tidy up, re-split, squash or rewrite a feature branch's commit history before review.
---

# Recommit

Split instructions: $ARGUMENTS

If `$ARGUMENTS` is unresolved, use any split instructions in the user's request.

Rebuild the commits on the current branch as a sequence a reviewer can read top
to bottom. The work lands on a new branch; the original is never modified.

## 1. Refuse unless the ground is solid

Stop and report if any of these hold:

- `git status --porcelain` is non-empty. Uncommitted work is not in scope.
- HEAD is detached, or the current branch is the default branch.
- `git merge-base` against the base yields nothing, or the branch has no commits
  beyond it.

Resolve the base in this order: an explicit argument, then
`git symbolic-ref --short refs/remotes/origin/HEAD`, then `main`, then `master`.

## 2. Establish the target

Record `source=$(git branch --show-current)` and `tip=$(git rev-parse HEAD)`.
Report both; `tip` is the whole undo story, so the user can always get back with
`git switch $source`.

Then:

```sh
git switch -c "$source-recommit"
git reset --soft "$(git merge-base "$base" HEAD)"
```

The new branch now holds every change from the branch as one staged diff, and
`$source` still points at `$tip`. Re-partitioning that staged diff cannot alter
the end state, which is why this is preferred over replaying the work by hand.

## 3. Decide the verification command

Each commit has to stand on its own, so find what proves that. Look for the
repo's own gate, cheapest sufficient one first: a `just`/`make` target, the test
or typecheck script in `package.json`, `cargo check`, `nix flake check`, the
CI workflow's commands. Ask the user once if nothing is conclusive, and offer
to proceed without per-commit verification as an explicit choice.

## 4. Plan the sequence

Read the full staged diff before planning anything. Then write the plan out and
show it to the user before the first commit.

- One idea per commit. A reviewer should be able to state what each commit does
  without reading the diff twice.
- Order for the reader: mechanical changes first (renames, moves, formatting,
  generated files), then the behaviour that depends on them. Noise up front,
  substance after.
- Never split a commit so that it leaves the tree broken. A commit that only
  compiles once the next one lands belongs merged into it.
- Follow the user's split instructions when given. With none, choose the
  smallest set of commits that still tells the story; one commit is a fine
  answer for a small branch.

## 5. Build it

For each planned commit:

1. Stage only its changes (`git add -p`, or by path when the split is clean).
2. Commit, matching the subject style already in `git log`.
3. Run the verification command from section 3. If it fails, fix it inside that
   commit with `git commit --amend` rather than deferring to a later one.

Never `git add -A`; that defeats the split.

## 6. Prove nothing was lost

`git diff --stat "$source"` must print nothing. If it doesn't, the rebuild
dropped or invented something: report the difference and stop, leaving both
branches in place.

## 7. Stop

Report the new branch, the commit list, and each commit's verification result.

Do not push. Do not open a pull request. Do not delete, move or force-update
`$source`. If the user wants any of that, they will ask.
