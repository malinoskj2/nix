# shellcheck shell=bash
set -euo pipefail

script=$1
root=$PWD
export HOME=$root/home GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" stubs
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main
git config --global hook.betterleaks-push-gate.event pre-push
git config --global hook.betterleaks-push-gate.command true
git config --global url."$root/origin.git".insteadOf git@example.com:nix.git
printf '#!/bin/sh\nexit 0\n' >stubs/bot-sandbox-refresh
# The lint build reports LINT_STATUS, or fails to build when it is "error".
cat >stubs/nix <<STUB
#!/bin/sh
[ "\$1" = build ] || exit 0
echo "\$@" >>"$root/lint-builds"
[ "\$LINT_STATUS" = error ] && { echo 'error: build failed' >&2; exit 1; }
mkdir -p "$root/report"
echo "\$LINT_STATUS" >"$root/report/status"
: >"$root/report/log"
echo "$root/report"
STUB
export NIX_LAND_LINT=$root/lint.nix LINT_STATUS=0
cat >stubs/host-switch <<EOF
#!/bin/sh
echo "\$@" >"$root/switched"
echo "host-switch: switched to \$2"
EOF
chmod +x stubs/*
export PATH=$root/stubs:$PATH

setup() {
  rm -rf origin.git nix switched
  git init --quiet --bare origin.git
  git init --quiet nix
  git -C nix commit --quiet --allow-empty -m base
  git -C nix remote add origin git@example.com:nix.git
  git -C nix push --quiet origin main main:gone
  git -C nix fetch --quiet origin
  git -C nix pack-refs --all
  git -C origin.git branch --quiet -D gone
  git -C nix branch work
  git -C nix worktree add --quiet ../work-tree work
  git -C work-tree commit --quiet --allow-empty -m work
  rm -rf work-tree
  git -C nix worktree prune
}

land() {
  NIX_LAND_REPO=$root/nix bash -o errexit -o nounset -o pipefail "$script" "$@" 2>stderr | tail -n 1
}

expect_failure() {
  local stage=$1 out
  out=$(land work) || true
  if [[ $out != "FAILED $stage "* ]]; then
    echo "expected FAILED $stage, got: $out" >&2
    cat stderr >&2
    exit 1
  fi
}

setup
out=$(land work)
merged=$(git -C nix rev-parse main)
[[ $out == "LANDED $merged" ]] || {
  echo "landing failed: $out" >&2
  cat stderr >&2
  exit 1
}
[[ $(git -C origin.git rev-parse main) == "$merged" ]]
if git -C nix rev-parse --verify --quiet refs/remotes/origin/gone; then
  echo 'the landing did not prune origin/gone' >&2
  exit 1
fi
[[ $(<switched) == "--expect $merged" ]]
if git -C nix worktree list --porcelain | grep -v "^worktree $root/nix$" | grep -q '^worktree '; then
  echo 'the landing left a worktree behind' >&2
  exit 1
fi

setup
git -C nix commit --quiet --allow-empty -m unpushed
expect_failure preflight
grep -q 'is not origin/main' stderr

setup
git -C nix config core.fsmonitor "touch $root/pwned"
expect_failure preflight
[[ ! -e pwned ]]

setup
printf '#!/bin/sh\ntouch %s/pwned\n' "$root" >nix/.git/hooks/post-merge
chmod +x nix/.git/hooks/post-merge
expect_failure preflight
[[ ! -e pwned ]]

rust_branch() {
  setup
  git -C nix switch --quiet work
  mkdir -p nix/crates/app/src
  printf '[package]\nname = "app"\nversion = "0.1.0"\n' >nix/crates/app/Cargo.toml
  echo 'pub fn f() {}' >nix/crates/app/src/lib.rs
  if [[ $1 == locked ]]; then
    : >nix/crates/app/Cargo.lock
  fi
  git -C nix add -A
  git -C nix commit --quiet -m rust
  git -C nix switch --quiet main
  rm -f lint-builds
}

rust_branch locked
out=$(land work)
[[ $out == LANDED* ]] || {
  echo "clean Rust did not land: $out" >&2
  cat stderr >&2
  exit 1
}
grep -q -- '--argstr manifest crates/app/Cargo.toml' lint-builds

rust_branch locked
LINT_STATUS=1 expect_failure rust-lints
grep -q 'lint findings in crates/app/Cargo.toml' stderr

rust_branch locked
LINT_STATUS=2 expect_failure rust-lints

rust_branch locked
LINT_STATUS=error expect_failure rust-lints
grep -q 'could not run rust-lints' stderr

rust_branch unlocked
expect_failure rust-lints
[[ ! -e lint-builds ]]

setup
git -C nix switch --quiet --detach
git -C nix worktree add --quiet ../elsewhere main
expect_failure update-main
