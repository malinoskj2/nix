# shellcheck shell=bash
set -euo pipefail

fresh() {
  rm -rf repo
  git init -q -b main repo
  git -C repo remote add origin git@github.com:example/nix.git
  git -C repo config branch.main.remote origin
  git -C repo config branch.main.merge refs/heads/main
  git -C repo config branch.feature/a.b.base refs/heads/main
  git -C repo config push.autoSetupRemote true
}

refuses() {
  local why=$1
  shift
  fresh
  "$@"
  if git-repo-guard repo 2>err; then
    echo "accepted a repository with $why" >&2
    exit 1
  fi
  grep -q git-repo-guard: err
}

fresh
git-repo-guard repo

refuses 'an fsmonitor' git -C repo config core.fsmonitor 'touch pwned'
refuses 'an ssh command' git -C repo config core.sshCommand 'sh -c pwned'
refuses 'a pager' git -C repo config core.pager less
refuses 'an editor' git -C repo config core.editor vi
refuses 'a hooks path' git -C repo config core.hooksPath /tmp
refuses 'a config hook' git -C repo config hook.x.command pwned
refuses 'an include' git -C repo config include.path /tmp/evil
refuses 'a conditional include' git -C repo config includeIf.gitdir:/.path /tmp/evil
refuses 'a filter' git -C repo config filter.x.clean pwned
refuses 'a textconv' git -C repo config diff.x.textconv pwned
refuses 'a credential helper' git -C repo config credential.helper '!pwned'
refuses 'a gpg program' git -C repo config gpg.program pwned
refuses 'an extension' git -C repo config extensions.worktreeConfig true
refuses 'an upload-pack' git -C repo config remote.origin.uploadpack pwned
refuses 'a protocol allowance' git -C repo config protocol.ext.allow always
refuses 'an ext URL' git -C repo config remote.origin.url 'ext::sh -c pwned'
refuses 'a file URL' git -C repo config remote.origin.url /tmp/elsewhere
refuses 'a hook' sh -c 'printf "#!/bin/sh\n" >repo/.git/hooks/pre-commit'
refuses 'a hidden hook' sh -c 'touch repo/.git/hooks/.pre-push'
refuses 'a symlinked sample' sh -c 'ln -s /tmp/x repo/.git/hooks/evil.sample'
refuses 'a commondir' sh -c 'echo /tmp >repo/.git/commondir'
refuses 'a symlinked config' sh -c 'mv repo/.git/config repo/config && ln -s ../config repo/.git/config'
refuses 'a gitfile' sh -c 'mv repo/.git repo/.real && echo "gitdir: .real" >repo/.git'
refuses 'a symlinked hooks dir' sh -c 'rm -r repo/.git/hooks && ln -s /tmp repo/.git/hooks'

if git-repo-guard 2>/dev/null; then
  echo 'accepted no arguments' >&2
  exit 1
fi
