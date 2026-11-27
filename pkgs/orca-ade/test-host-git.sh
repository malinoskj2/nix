# shellcheck shell=bash
set -euo pipefail

tools=$1
real=$2
bwrap=$3
wrapper=$tools/git
root=$PWD
repo=$root/repo
export ORCA_HOST_GIT_PATH=$tools
export HOME=$root/home GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$root/bin"
echo secret-value >"$HOME/secret"
git config --global init.defaultBranch main
git config --global diff.trusted.textconv 'sed s/^/trusted:/'
git config --global credential.helper '!f() { echo username=u; echo pass""word=trusted; }; f'

guarded() { bash -o errexit -o nounset -o pipefail "$wrapper" "$@"; }

# A program the repository names. It marks the host, and copies the home directory's secret into
# the repository, where a sandbox could read it.
pwn() { printf "sh -c 'touch %s/pwned-%s; cat %s/secret >>%s/leak 2>/dev/null; cat \"\${1:--}\" 2>/dev/null || cat' _" "$root" "$1" "$HOME" "$repo"; }

check() {
  local pwned
  pwned=$(find "$root" -maxdepth 1 -name 'pwned-*' -printf '%f ')
  if [[ -n $pwned ]]; then
    echo "$1: repository config ran programs on the host: $pwned" >&2
    exit 1
  fi
  if grep -rqs secret-value "$repo"; then
    echo "$1: a repository program read the home directory" >&2
    exit 1
  fi
}

git init --quiet "$repo"
cd "$repo"
printf 'a\n' >f.txt
printf 'a\n' >g.dat
printf '*.txt filter=evil diff=evil merge=evil\n*.dat diff=trusted\n' >.gitattributes
git add .
git commit --quiet -m base
git clone --quiet --bare . "$root/upstream.git"
git config core.repositoryformatversion 1
git config core.fsmonitor "$(pwn fsmonitor)"
git config filter.evil.clean "$(pwn clean)"
git config filter.evil.smudge "$(pwn smudge)"
git config diff.evil.textconv "$(pwn textconv)"
git config diff.evil.command "$(pwn diffcommand)"
git config diff.external "$(pwn external)"
git config merge.evil.driver "$(pwn merge)"
git config core.pager "$(pwn pager)"
git config core.editor "$(pwn editor)"
git config core.sshCommand "$(pwn ssh)"
git config core.askPass "$(pwn askpass)"
git config credential.helper "!$(pwn credential)"
git config 'credential.https://example.com.helper' "!$(pwn credential-url)"
git config gpg.program "$(pwn gpg)"
git config remote.origin.url "$root/upstream.git"
git config remote.origin.uploadpack "$(pwn uploadpack)"
git config hook.evil.event reference-transaction
git config hook.evil.command "$(pwn config-hook)"
for hook in reference-transaction pre-commit post-checkout; do
  printf '#!/bin/sh\ntouch %s/pwned-%s\nexit 0\n' "$root" "$hook" >".git/hooks/$hook"
  chmod +x ".git/hooks/$hook"
done

# Helpers the repository selects, by remote.*.vcs or a <transport>:: URL, and protocol overrides.
mkdir -p git-remote-proof
printf '#!/bin/sh\ntouch %s/pwned-remote-helper\n' "$root" >git-remote-proof/helper
chmod +x git-remote-proof/helper
git config remote.proof.url ignored
git config remote.proof.vcs proof/helper
git config protocol.allow always
git config protocol.ext.allow always
git config url."ext::sh -c touch% $root/pwned-ext".insteadOf https://insteadof.invalid/
if guarded fetch proof 2>/dev/null; then exit 1; fi
if guarded ls-remote 'proof/helper::x' 2>/dev/null; then exit 1; fi
if guarded ls-remote "ext::sh -c touch% $root/pwned-ext" 2>/dev/null; then exit 1; fi
if guarded ls-remote https://insteadof.invalid/x 2>/dev/null; then exit 1; fi
# Local transports, which would run uploadpack, aren't allowed on the host.
if guarded fetch --quiet origin 2>/dev/null; then exit 1; fi
check transports

# gc.recentObjectsHook runs on prune, gc and the housekeeping fetch starts. Plain Git runs it in
# each case; through the wrapper it runs only in the jail. A local alternate's refs come from
# core.alternateRefsCommand.
export ORCA_HOST_GIT_PROTOCOLS=file
git clone --quiet --bare "$root/upstream.git" "$root/hk-up.git"
git clone --quiet "$root/hk-up.git" "$root/hk-bump"
bump() {
  git -C "$root/hk-bump" commit --quiet --allow-empty -m bump
  git -C "$root/hk-bump" push --quiet origin HEAD:main
}
for side in control guarded; do
  git clone --quiet "$root/hk-up.git" "$root/hk-$side"
  git -C "$root/hk-$side" config gc.autoDetach false
  git -C "$root/hk-$side" config maintenance.autoDetach false
  git -C "$root/hk-$side" config fetch.unpackLimit 1
  git -C "$root/hk-$side" config gc.autoPackLimit 1
  git -C "$root/hk-$side" config gc.auto 1
  git -C "$root/hk-$side" config gc.pruneExpire now
  git -C "$root/hk-$side" config maintenance.strategy gc
  git init --quiet --bare "$root/hk-alt-$side.git"
  echo "$root/hk-alt-$side.git/objects" >"$root/hk-$side/.git/objects/info/alternates"
done
ctl() { printf "sh -c 'touch $root/control-%s; cat >/dev/null' _" "$1"; }
for op in prune gc fetch; do
  git -C "$root/hk-control" config gc.recentObjectsHook "$(ctl "$op")"
  git -C "$root/hk-control" config core.alternateRefsCommand "$(ctl "alternates-$op")"
  git -C "$root/hk-guarded" config gc.recentObjectsHook "$(pwn "objects-hook-$op")"
  git -C "$root/hk-guarded" config core.alternateRefsCommand "$(pwn "alternates-$op")"
  # The hook runs when unreachable objects are about to expire.
  for side in control guarded; do
    echo "$op" | git -C "$root/hk-$side" hash-object -w --stdin >/dev/null
  done
  case $op in
    prune)
      git -C "$root/hk-control" prune
      guarded -C "$root/hk-guarded" prune
      ;;
    gc)
      git -C "$root/hk-control" gc --quiet
      guarded -C "$root/hk-guarded" gc --quiet
      ;;
    fetch)
      for _ in 1 2; do
        bump
        git -C "$root/hk-control" fetch --quiet origin
        bump
        guarded -C "$root/hk-guarded" fetch --quiet origin
      done
      [[ -e $root/control-alternates-fetch ]]
      ;;
  esac
  [[ -e $root/control-$op ]]
  check "housekeeping $op"
done
unset ORCA_HOST_GIT_PROTOCOLS

# Before every Git process the wrapper starts, the repository gains drivers, an include, attributes
# and hooks under names no earlier process could have seen.
cat >"$root/bin/racing-git" <<RACE
#!$BASH
n=\$(cat "$root/race-count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo \$n >"$root/race-count"
if [[ -w "$repo/.git/config" ]]; then
  pwn() { printf "sh -c 'touch $root/pwned-%s; cat $HOME/secret >>$repo/leak 2>/dev/null; cat \\"\\\${1:--}\\" 2>/dev/null || cat' _" "\$1"; }
  git() { "$real" -C "$repo" "\$@"; }
  git config "diff.late\$n.textconv" "\$(pwn late-textconv)"
  git config "filter.late\$n.clean" "\$(pwn late-clean)"
  git config "filter.late\$n.smudge" "\$(pwn late-smudge)"
  git config "hook.late\$n.event" reference-transaction
  git config "hook.late\$n.command" "\$(pwn late-hook)"
  git config core.fsmonitor "\$(pwn late-fsmonitor)"
  "$real" config --file "$repo/.git/included" "diff.include\$n.textconv" "\$(pwn late-include)"
  git config include.path "$repo/.git/included"
  printf '*.txt diff=late%s filter=late%s\n*.txt diff=include%s\n' "\$n" "\$n" "\$n" >"$repo/.git/info/attributes"
fi
exec "$real" "\$@"
RACE
chmod +x "$root/bin/racing-git"
export ORCA_HOST_GIT_REAL=$root/bin/racing-git

printf 'b\n' >>f.txt
printf 'b\n' >>g.dat
guarded status --short >/dev/null
guarded diff >"$root/diff"
guarded -C . log -p -1 >/dev/null
guarded show HEAD >/dev/null
guarded diff HEAD --stat >/dev/null
guarded add f.txt g.dat
guarded commit --quiet -m change
guarded checkout --quiet HEAD~1 -- f.txt
guarded cat-file --textconv HEAD:f.txt >/dev/null
guarded cat-file --textc HEAD:f.txt >/dev/null
# These used to run on the host; reflog shows patches through the repository's textconv.
guarded reflog -p -1 >/dev/null
guarded rev-list --format=%s -1 HEAD >/dev/null
guarded name-rev HEAD >/dev/null
guarded ls-tree HEAD >/dev/null
guarded for-each-ref >/dev/null
guarded config --get core.bare >/dev/null
guarded worktree list >/dev/null
guarded update-ref refs/heads/raced HEAD
guarded branch --quiet raced-too
guarded tag raced-tag
[[ $(cat "$root/race-count") -ge 20 ]]
check race

grep -q '^+b$' "$root/diff"
grep -q 'trusted:b' "$root/diff"
[[ $(git log -1 --format=%s) == change ]]

# A worktree's own config and attributes, behind extensions.worktreeConfig.
git config extensions.worktreeConfig true
guarded worktree add --quiet -b feat "$root/workspaces/feat"
git -C "$root/workspaces/feat" config --worktree diff.wt.textconv "$(pwn worktree-config)"
echo '*.txt diff=wt' >>"$root/workspaces/feat/.gitattributes"
printf 'c\n' >>"$root/workspaces/feat/f.txt"
(cd "$root/workspaces/feat" && guarded diff >/dev/null && guarded status --short >/dev/null)
guarded worktree add --quiet -b other "$root/workspaces/other"
# Sandboxes can write ~/.orca/bots, but not Tohru's home inside it.
bots=$HOME/.orca/bots
mkdir -p "$bots/tohru"
echo soul >"$bots/tohru/SOUL.md"
(guarded worktree move "$root/workspaces/other" "$bots/other" 2>&1 >/dev/null || true) | grep -q "won't expose"
guarded worktree add --quiet -b gone "$root/workspaces/gone"
rm -rf "$root/workspaces/gone"
guarded worktree remove --force "$root/workspaces/gone"
guarded worktree remove --force feat
guarded worktree remove --force other
[[ ! -e $root/workspaces/feat && ! -e $root/workspaces/other ]]
check worktrees

# A linked worktree's Git directory names the common directory, which must itself be a Git
# directory, not ~/.orca/bots around Tohru's home.
git init --quiet --bare "$bots"
mkdir -p "$bots/worktrees/pwn" "$root/escape"
echo ../.. >"$bots/worktrees/pwn/commondir"
echo 'ref: refs/heads/main' >"$bots/worktrees/pwn/HEAD"
echo "$root/escape/.git" >"$bots/worktrees/pwn/gitdir"
git --git-dir="$bots" config diff.pwn.textconv "sh -c 'echo pwned >$bots/tohru/SOUL.md; cat \"\$1\"' _"
echo "gitdir: $bots/worktrees/pwn" >"$root/escape/.git"
echo '*.txt diff=pwn' >"$root/escape/.gitattributes"
echo a >"$root/escape/a.txt"
(cd "$root/escape" && guarded diff 2>&1 >/dev/null || true) | grep -q 'refusing Git directory'
[[ $(cat "$bots/tohru/SOUL.md") == soul ]]

# The jail mounts what was checked, even when a parent is swapped for a symlink into the home
# directory before bubblewrap runs.
mkdir -p "$HOME/target"
echo secret-value >"$HOME/target/secret"
git init --quiet "$root/stage/target"
(
  cd "$root/stage/target"
  echo a >s.txt
  echo '*.txt diff=peek' >.gitattributes
  git add .
  git commit --quiet -m swap
  git config diff.peek.textconv "sh -c 'cat secret >>leak 2>/dev/null; touch jail-ran; cat \"\$1\"' _"
  echo b >>s.txt
)
cat >"$root/bin/swapping-bwrap" <<SWAP
#!$BASH
mv "$root/stage" "$root/stage.real"
ln -s "$HOME" "$root/stage"
exec "$bwrap" "\$@"
SWAP
chmod +x "$root/bin/swapping-bwrap"
(cd "$root/stage/target" && ORCA_HOST_GIT_BWRAP=$root/bin/swapping-bwrap guarded diff >/dev/null)
rm "$root/stage"
mv "$root/stage.real" "$root/stage"
[[ -e $root/stage/target/jail-ran && ! -e $HOME/target/leak && ! -e $HOME/target/jail-ran ]]

# Pull and clone fetch on the host and merge or check out in the jail.
export ORCA_HOST_GIT_PROTOCOLS=file
git config --unset remote.origin.uploadpack
git -C "$root/upstream.git" fetch --quiet "$repo" main:main
guarded pull --quiet --ff-only origin main
[[ -z $(git for-each-ref refs/orca-host-git) ]]
guarded clone --quiet "$root/upstream.git" "$root/clone"
[[ -f $root/clone/f.txt ]]
(cd "$root" && guarded clone --quiet -- "$root/upstream.git")
[[ -f $root/upstream/f.txt ]]
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
guarded fetch --quiet origin
guarded branch --quiet --set-upstream-to=origin/main
guarded pull --quiet --ff-only origin
guarded pull --quiet --depth 5 --ff-only origin main
guarded branch --quiet --set-upstream-to=raced
guarded pull --quiet --no-rebase
[[ -z $(git for-each-ref refs/orca-host-git) ]]
check pull

# Only system and global config choose pre-push hooks, so Betterleaks always runs and nothing the
# repository adds does.
git config --global hook.gate.event pre-push
git config --global hook.gate.command "sh -c 'cat >>$root/gate-stdin; [ ! -e $root/gate-deny ]'"
git config hook.gate.command "$(pwn gate-override)"
git config hook.gate.enabled false
git config hook.pre-push.enabled true
git config hook.push-evil.event pre-push
git config hook.push-evil.command "$(pwn push-config-hook)"
printf '#!/bin/sh\ntouch %s/pwned-pre-push\n' "$root" >.git/hooks/pre-push
chmod +x .git/hooks/pre-push
guarded push --quiet origin HEAD:refs/heads/pushed
grep -q ' refs/heads/pushed ' "$root/gate-stdin"
touch "$root/gate-deny"
if guarded push --quiet origin HEAD:refs/heads/denied 2>/dev/null; then exit 1; fi
[[ -z $(git -C "$root/upstream.git" for-each-ref refs/heads/denied) ]]
git config --global --unset hook.gate.event
unset ORCA_HOST_GIT_PROTOCOLS
check push

# Help runs the repository's man or browser command, so it only runs in the jail.
git config help.format man
git config man.viewer pwn
git config man.pwn.cmd "$(pwn man)"
for cmd in fetch push ls-remote credential version remote help; do
  guarded "$cmd" --help >/dev/null 2>&1 || true
done
guarded help fetch >/dev/null 2>&1 || true
git config help.format web
git config web.browser pwnb
git config browser.pwnb.cmd "$(pwn browser)"
guarded fetch --help >/dev/null 2>&1 || true
git config --remove-section man.pwn
git config --unset man.viewer
git config --remove-section browser.pwnb
git config --unset web.browser
git config --unset help.format
check help

# The caller's --git-dir and --work-tree, in either order and form, choose the work tree.
mkdir -p "$repo/sub"
(
  cd "$repo/sub"
  guarded --git-dir="$repo/.git" --work-tree="$repo" status --short >/dev/null
  guarded --work-tree="$repo" --git-dir="$repo/.git" status --short >/dev/null
  guarded --git-dir "$repo/.git" --work-tree "$repo" status --short >/dev/null
  guarded --work-tree "$repo" --git-dir "$repo/.git" status --short >/dev/null
)
# Outside a repository the home directory stays hidden, and global config still reads.
[[ $(cd "$HOME" && guarded config --global --get init.defaultBranch) == main ]]

creds=$(printf 'protocol=https\nhost=example.com\n\n' | guarded credential fill)
[[ $creds == *pass"word"=trusted* ]]
check credentials

if guarded push --no-verify origin main 2>/dev/null; then exit 1; fi

# A path the repository names is only exposed when it belongs to the work tree Orca chose.
git init --quiet "$root/private"
mkdir "$root/pointer"
echo "gitdir: $root/private/.git" >"$root/pointer/.git"
(cd "$root/pointer" && guarded status 2>&1 >/dev/null || true) | grep -q 'refusing Git directory'
git config core.worktree "$HOME"
(guarded status 2>&1 >/dev/null || true) | grep -q "doesn't contain"
git config --unset core.worktree
# The work tree is where Orca's directory finds its .git, not what repository config names.
git init --quiet "$HOME/projects/r"
for tree in "$HOME" "$(dirname "$HOME")" "$HOME/.orca/bots" "$HOME/projects"; do
  git -C "$HOME/projects/r" config core.worktree "$tree"
  (cd "$HOME/projects/r" && guarded status 2>&1 >/dev/null || true) | grep -qE "refusing work tree|doesn't contain"
done
git -C "$HOME/projects/r" config --unset core.worktree
(cd "$HOME/projects/r" && guarded status --short >/dev/null)

# gh runs the git it finds on PATH.
{
  echo "#!$BASH"
  cat <<'GH'
git status --short >/dev/null
git diff >/dev/null
echo "gh $*"
GH
} >"$root/bin/gh"
chmod +x "$root/bin/gh"
[[ $(PATH=$root/bin:$PATH "$tools/gh" pr view) == 'gh pr view' ]]
if missing=$(PATH=$root/bin:$PATH "$tools/glab" mr list 2>&1); then exit 1; fi
[[ $missing == 'spawn glab ENOENT' ]]
check gh

cd "$root"
git init --quiet plain
guarded -C plain status --short >/dev/null
guarded --version >/dev/null
if guarded --exec-path="$root/bin" status 2>/dev/null; then exit 1; fi

# Orca's layout: a repository and its worktrees in separate directories of the home directory,
# which the jail hides. Orca must see what Git sees.
app=$HOME/projects/app
ws=$HOME/orca/workspaces/app
git init --quiet "$app"
mkdir "$app/sub"
echo a >"$app/sub/a.txt"
git -C "$app" add .
git -C "$app" commit --quiet -m base
guarded -C "$app" worktree add --quiet -b w1 "$ws/w1"
guarded -C "$app" worktree add --quiet -b w2 "$ws/w2"
guarded -C "$app" worktree add --quiet -b nested "$app/.worktrees/nested"
[[ -f $ws/w1/sub/a.txt && ! -e $app/.git/worktrees/w1/locked ]]
git -C "$app" worktree add --quiet -b stale "$ws/stale"
rm -rf "$ws/stale"
echo b >>"$app/sub/a.txt"
echo b >>"$ws/w1/sub/a.txt"
echo u >"$ws/w1/untracked"
same() {
  cmp <(guarded "$@") <(git "$@") || {
    echo "differs from Git: $*" >&2
    exit 1
  }
}
for dir in "$app" "$app/sub" "$ws/w1" "$ws/w1/sub" "$app/.worktrees/nested"; do
  (
    cd "$dir"
    same status --porcelain=v2 --branch -z --untracked-files=all
    same status --porcelain -z
    same rev-parse --show-toplevel --git-dir --git-common-dir --absolute-git-dir --show-prefix --show-cdup
    same rev-parse --path-format=relative --git-dir --git-common-dir
    same rev-parse HEAD --symbolic-full-name HEAD
    same diff --numstat HEAD
    same diff -- ../sub/a.txt
    same worktree list --porcelain -z
    same worktree list
    same for-each-ref '--format=%(refname)%00%(upstream)%00%(worktreepath)' refs/heads
    same branch -vv
    same log -1 --format=%H%x00%s
  )
done
grep -q "prunable gitdir file points to non-existent location" <(guarded -C "$app" worktree list --porcelain)
[[ $(guarded -C "$app" worktree list --porcelain | grep -c '^prunable') == 1 ]]
# A branch checked out in another worktree stays protected.
if guarded -C "$app" branch -D w1 2>/dev/null; then exit 1; fi
if guarded -C "$app" checkout --quiet w2 2>/dev/null; then exit 1; fi
guarded -C "$ws/w1" branch -m w1 w1-renamed
[[ $(git -C "$ws/w1" symbolic-ref --short HEAD) == w1-renamed ]]

# Prune can't tell a hidden worktree that moved or has no index yet from a deleted one, so it
# does nothing, while a worktree moves or is added under it.
git -C "$app" worktree add --quiet -b live "$ws/live"
touch -d 2000-01-01 "$app/.git/worktrees/live/index"
race() {
  cat >"$root/bin/prune-race" <<PRUNE
#!$BASH
if [[ "\$*" == *'worktree list --porcelain -z'* ]] && mkdir "$root/prune-raced" 2>/dev/null; then
  $real "\$@" || exit
  exec $real -C "$app" $1 >/dev/null
fi
exec $real "\$@"
PRUNE
  chmod +x "$root/bin/prune-race"
  rm -rf "$root/prune-raced"
  ORCA_HOST_GIT_REAL=$root/bin/prune-race guarded -C "$app" worktree prune 2>&1 | grep -q 'skipped worktree prune'
  # Prune takes no snapshot to race now, so the change comes after it, then prune runs again.
  if mkdir "$root/prune-raced" 2>/dev/null; then
    read -ra change <<<"$1"
    git -C "$app" "${change[@]}" >/dev/null
  fi
  guarded -C "$app" worktree prune 2>/dev/null
}
race "worktree move $ws/live $ws/moved"
race "worktree add --quiet --no-checkout -b new $ws/new"
(cd "$ws/w1" && guarded worktree prune 2>/dev/null)
for wt in w1 w2 nested live new stale; do
  [[ -d $app/.git/worktrees/$wt ]]
done
git -C "$ws/moved" status --short >/dev/null
# Housekeeping prunes a hidden worktree without an index whatever its expiry, so gc and
# maintenance don't run, and no command starts them on its own.
git -C "$app" worktree add --quiet --no-checkout -b idle "$ws/idle"
touch -d 2000-01-01 "$app/.git/worktrees/w2/index" "$app/.git/worktrees/stale/index"
git -C "$app" config gc.auto 1
git -C "$app" config gc.autoDetach false
git -C "$app" config maintenance.autoDetach false
git -C "$app" config maintenance.worktree-prune.enabled true
kept() {
  for wt in idle w2 stale; do
    [[ -d $app/.git/worktrees/$wt ]] || {
      echo "$1 pruned worktrees/$wt" >&2
      exit 1
    }
  done
}
guarded -C "$app" gc --quiet 2>&1 | grep -q 'skipped gc'
kept gc
guarded -C "$app" gc --auto 2>/dev/null
kept 'gc --auto'
for task in gc commit-graph prefetch loose-objects incremental-repack pack-refs reflog-expire worktree-prune rerere-gc; do
  guarded -C "$app" maintenance run "--task=$task" 2>&1 | grep -q 'skipped maintenance'
  kept "maintenance $task"
done
for args in 'run --auto' 'run' register start; do
  read -ra a <<<"$args"
  guarded -C "$app" maintenance "${a[@]}" 2>/dev/null
  kept "maintenance $args"
done
guarded -C "$app" pack-refs --all --prune
guarded -C "$app" repack --quiet -d
guarded -C "$app" multi-pack-index write
kept "Orca's own maintenance"
guarded -C "$app" worktree add --quiet -b hk "$ws/hk"
hk=$ws/hk
blob=$(echo side | git -C "$hk" hash-object -w --stdin)
tree=$( (git -C "$hk" ls-tree HEAD && printf '100644 blob %s\tside.txt\n' "$blob") | git -C "$hk" mktree)
side=$(git -C "$hk" commit-tree -p HEAD -m side "$tree")
git -C "$hk" branch side "$side"
git -C "$hk" format-patch --quiet -1 --stdout side >"$root/side.patch"
guarded -C "$hk" commit --quiet --allow-empty -m auto
kept commit
guarded -C "$hk" merge --quiet --no-ff --no-edit side
kept merge
guarded -C "$hk" reset --quiet --hard HEAD~1
guarded -C "$hk" cherry-pick side >/dev/null
kept cherry-pick
guarded -C "$hk" reset --quiet --hard HEAD~1
guarded -C "$hk" am --quiet <"$root/side.patch"
kept am
guarded -C "$hk" reset --quiet --hard HEAD~1
guarded -C "$hk" rebase --quiet side
kept rebase
guarded -C "$hk" reset --quiet --hard HEAD~1
guarded -C "$hk" pull --quiet --no-edit . side
kept pull
# Git's own prune deletes inside whatever an administrative directory links to, which is why
# none runs on the host either.
mkdir -p "$root/victim/keep"
ln -s "$root/victim" "$app/.git/worktrees/evil"
git -C "$app" worktree prune
[[ ! -e $root/victim/keep && ! -e $app/.git/worktrees/stale ]]
rm -f "$app/.git/worktrees/evil"
git -C "$app" worktree remove --force "$ws/moved"
rm -rf "$ws/new"
git -C "$app" worktree prune
guarded -C "$app" worktree lock --reason kept "$ws/w1"
[[ $(cat "$app/.git/worktrees/w1/locked") == kept ]]
guarded -C "$app" worktree unlock w1
[[ ! -e $app/.git/worktrees/w1/locked ]]
echo /moved/.git >"$app/.git/worktrees/w1/gitdir"
guarded -C "$app" worktree repair "$ws/w1" 2>/dev/null
[[ $(cat "$app/.git/worktrees/w1/gitdir") == "$ws/w1/.git" ]]
guarded -C "$app" worktree add --quiet -b moving "$ws/prepared"
guarded -C "$app" worktree move -f -f "$ws/prepared" "$ws/final"
[[ -f $ws/final/sub/a.txt ]]
same -C "$app" worktree list --porcelain -z
guarded -C "$app" worktree remove --force -- "$ws/final"
[[ ! -e $ws/final && ! -e $app/.git/worktrees/prepared ]]
guarded -C "$app" worktree remove --force -- "$ws/w2"
[[ ! -e $ws/w2 ]]

# New repositories land where Orca asked, from anywhere, and a write outside the repository fails
# instead of vanishing with the jail.
(cd "$HOME" && guarded init --quiet "$HOME/projects/new")
(cd "$HOME" && guarded init --quiet projects/relative)
(cd "$root" && guarded init --quiet --template= "$HOME/projects/templated")
[[ -d $HOME/projects/new/.git && -d $HOME/projects/relative/.git && -d $HOME/projects/templated/.git ]]
(cd "$HOME" && guarded init --quiet 2>&1 || true) | grep -q "won't initialize"
[[ ! -e $HOME/.git ]]
(guarded -C "$app" archive -o "$HOME/out.tar" HEAD 2>&1 || true) | grep -qi 'read-only'
[[ ! -e $HOME/out.tar ]]
export ORCA_HOST_GIT_PROTOCOLS=file
(cd "$HOME" && guarded clone --quiet "file://$app" projects/clone)
[[ -f $HOME/projects/clone/sub/a.txt ]]
guarded -C "$HOME/projects/new" remote add -f app "file://$app"
git -C "$HOME/projects/new" rev-parse --verify --quiet refs/remotes/app/main >/dev/null
unset ORCA_HOST_GIT_PROTOCOLS
check layout
