# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: nix-land [--dry-run] [--no-switch] [--no-refresh] <branch>

Merge <branch> into main of the nix repository in a temporary clone, run
`nix flake check` and rust-lints on any Rust the branch changes, push main
(through the Betterleaks push gate), move the local main, run host-switch and
then bot-sandbox-refresh. It prunes stale remote-tracking refs, which sandboxes can't. Local main must equal origin/main, and the repository
must pass git-repo-guard; git runs without the repository's hooks or fsmonitor.

  --dry-run     merge and check only; push, main, switch and refresh are skipped
  --no-switch   stop after pushing and moving main
  --no-refresh  skip restarting idle bots' sandboxes after the switch

The last line of output is LANDED <sha>, CHECKED <sha> after a dry run, or
FAILED <stage> <reason>. Every failure exits nonzero. The full log goes to
<repo>/.tmp/nix-land/.

Environment: NIX_LAND_REPO (default /home/jesse/nix).
USAGE
}

repo=${NIX_LAND_REPO:-/home/jesse/nix}
dry_run='' switch=1 refresh=1 branch=''
while (($#)); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --no-switch) switch='' ;;
    --no-refresh) refresh='' ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      echo "FAILED usage unknown option $1"
      exit 2
      ;;
    *)
      if [[ -n $branch ]]; then
        usage >&2
        echo 'FAILED usage only one branch can be landed at a time'
        exit 2
      fi
      branch=$1
      ;;
  esac
  shift
done
if [[ -z $branch ]]; then
  usage >&2
  echo 'FAILED usage no branch given'
  exit 2
fi

# The push gate's bypass belongs to the human; never inherit it.
unset BETTERLEAKS_PUSH_BYPASS
export GIT_TERMINAL_PROMPT=0

# Sandboxes write objects, branches and worktree admin directories into the repository, so no
# hook, fsmonitor or other repository-controlled program runs here. The push gate is a global
# config hook, which core.hooksPath leaves alone. Housekeeping never starts, since it would run
# gc.recentObjectsHook.
git() {
  command git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.alternateRefsCommand=true \
    -c gc.auto=0 -c maintenance.auto=false "$@"
}

wt=''
cleanup() {
  if [[ -n $wt && -d $wt ]]; then
    chmod -R u+w -- "$wt" 2>/dev/null || true
    rm -rf -- "$wt"
  fi
}
trap cleanup EXIT

fail() {
  local stage=$1
  shift
  echo "nix-land: $stage failed: $*" >&2
  [[ -n ${log:-} ]] && echo "nix-land: log: $log" >&2
  echo "FAILED $stage $*" | tr '\n' ' ' | sed 's/ *$//'
  echo
  exit 1
}

say() { echo "nix-land: $*" >&2; }

guard_out=$(git-repo-guard "$repo" 2>&1) || fail preflight "${guard_out//$'\n'/; }"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || fail preflight "$repo is not a git repository"
log_dir=$repo/.tmp/nix-land
mkdir -p "$log_dir" || fail preflight "cannot create $log_dir"
log=$log_dir/$(date +%Y%m%dT%H%M%S)-${branch//\//_}.log
: >"$log"

# One landing at a time: the lock covers everything from reading main to the switch.
lock=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/nix-land.lock
exec 9>"$lock" || fail preflight "cannot open $lock"
flock -n 9 || fail preflight "another nix-land is running (lock $lock)"

branch_sha=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}") ||
  fail preflight "no local branch $branch"
main_old=$(git -C "$repo" rev-parse --verify --quiet 'refs/heads/main^{commit}') ||
  fail preflight 'no local main'

if [[ -z $dry_run ]]; then
  # Sandboxes can't prune: deleting a ref rewrites packed-refs, which they only read.
  say "fetching origin"
  git -C "$repo" fetch --quiet --prune origin >>"$log" 2>&1 || fail preflight 'git fetch --prune origin failed'
  remote_main=$(git -C "$repo" rev-parse refs/remotes/origin/main)
  # A local main that differs from origin/main holds commits nobody pushed, possibly a sandbox's.
  [[ $remote_main == "$main_old" ]] ||
    fail preflight "local main ($main_old) is not origin/main ($remote_main); reconcile them first"
fi

if git -C "$repo" merge-base --is-ancestor "$branch_sha" "$main_old"; then
  fail preflight "$branch is already in main"
fi
behind=$(git -C "$repo" rev-list --count "$branch_sha..$main_old")
say "$branch at ${branch_sha:0:12}, main at ${main_old:0:12}, branch is $behind commit(s) behind main"

# A clone outside every sandbox mount: a linked worktree's admin directory would sit in
# .git/worktrees, which sandboxes write. Fetching also checks every object's hash.
wt=$(mktemp -d "${TMPDIR:-/tmp}/nix-land.XXXXXX")
{
  git init --quiet --template= "$wt" &&
    git -C "$wt" fetch --quiet --no-tags "$repo" "refs/heads/main:refs/land/main" "refs/heads/$branch:refs/land/branch"
} >>"$log" 2>&1 || fail preflight 'cannot create the temporary clone'
[[ $(git -C "$wt" rev-parse refs/land/main) == "$main_old" && $(git -C "$wt" rev-parse refs/land/branch) == "$branch_sha" ]] ||
  fail preflight 'main or the branch moved while cloning; run nix-land again'
git -C "$wt" switch --quiet --detach "$main_old" >>"$log" 2>&1 || fail preflight 'cannot check out main in the clone'
cd "$wt" || fail preflight "cannot enter $wt"

say "merging $branch into main"
if ! git merge --no-edit "$branch_sha" -m "Merge branch '$branch'" >>"$log" 2>&1; then
  conflicts=$(git diff --name-only --diff-filter=U | head -n 10 | paste -sd, -)
  git merge --abort >/dev/null 2>&1 || true
  if [[ -n $conflicts ]]; then
    fail merge "$branch is $behind commit(s) behind main and conflicts with it in: $conflicts; rebase it on main"
  fi
  fail merge "git merge failed; see the log"
fi
merged=$(git rev-parse HEAD)

mapfile -t rust_files < <(git diff --name-only --diff-filter=d "$main_old" "$merged" -- '*.rs' '*Cargo.toml' '*Cargo.lock')
manifests=()
for file in "${rust_files[@]}"; do
  # rust-lints' own Dylint crates build on a pinned nightly; its flake checks cover them.
  [[ $file == pkgs/rust-lints/* ]] && continue
  dir=$(dirname "$file")
  while [[ $dir != . && ! -f $dir/Cargo.toml ]]; do dir=$(dirname "$dir"); done
  [[ -f $dir/Cargo.toml ]] || continue
  # The workspace root is the nearest ancestor manifest with a [workspace] table; cargo itself
  # doesn't run on the host.
  manifest=$dir/Cargo.toml
  up=$dir
  while [[ $up != . ]]; do
    up=$(dirname "$up")
    if [[ -f $up/Cargo.toml ]] && grep -q '^\[workspace\]' "$up/Cargo.toml"; then
      manifest=$up/Cargo.toml
    fi
  done
  manifest=${manifest#./}
  [[ " ${manifests[*]} " == *" $manifest "* ]] || manifests+=("$manifest")
done
for manifest in "${manifests[@]}"; do
  say "rust-lints on $manifest, in a Nix build"
  [[ -f $(dirname "$manifest")/Cargo.lock ]] || fail rust-lints "$manifest has no Cargo.lock next to it to vendor its crates from"
  report=$(nix build --impure --no-link --print-out-paths --print-build-logs -f "$NIX_LAND_LINT" \
    --argstr src "$wt" --argstr rev "$merged" --argstr manifest "$manifest" 2>>"$log") ||
    fail rust-lints "could not run rust-lints for $manifest in a Nix build: $(grep -m1 -E '^error' "$log" | cut -c1-200)"
  cat "$report/log" >>"$log"
  lint_status=$(<"$report/status")
  case $lint_status in
    0) ;;
    1) fail rust-lints "lint findings in $manifest (report: $report/report.json)" ;;
    *) fail rust-lints "$manifest failed to build or a lint tool failed (exit $lint_status): $(grep -m1 -E '^error' "$report/log" | cut -c1-200)" ;;
  esac
done
((${#manifests[@]})) || say 'no changed Rust'

say "nix flake check (log: $log)"
nix flake check --keep-going --print-build-logs >>"$log" 2>&1 || fail flake-check "nix flake check failed: $(grep -m1 -E '^error' "$log" | cut -c1-200)"

if [[ -n $dry_run ]]; then
  say "dry run: not pushing $merged"
  echo "CHECKED $merged"
  exit 0
fi

[[ $(git rev-parse HEAD) == "$merged" ]] || fail flake-check "the clone's HEAD moved during the checks; it is no longer $merged"

main_wt=$(git -C "$repo" worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}')
# Any other worktree's path comes from an admin file a sandbox can write.
if [[ -n $main_wt && $main_wt != "$repo" ]]; then
  fail update-main "main is checked out in $main_wt, not $repo"
fi
if [[ -n $main_wt && -n $(git -C "$main_wt" status --porcelain --untracked-files=no) ]]; then
  fail update-main "main is checked out with uncommitted changes in $main_wt"
fi
[[ $(git -C "$repo" rev-parse refs/heads/main) == "$main_old" ]] || fail update-main 'local main moved during the checks; run nix-land again'

git -C "$repo" config --get hook.betterleaks-push-gate.event >/dev/null ||
  fail push 'the Betterleaks push gate is not configured for this git'

origin=$(git -C "$repo" remote get-url --push origin) || fail push 'no origin remote'
say "pushing $merged to origin/main"
git push "$origin" "$merged:refs/heads/main" >>"$log" 2>&1 ||
  fail push "git push was refused (Betterleaks or the remote); see the log"
{
  git -C "$wt" update-ref refs/heads/main "$merged" &&
    git -C "$repo" fetch --quiet --no-tags "$wt" refs/heads/main &&
    [[ $(git -C "$repo" rev-parse FETCH_HEAD) == "$merged" ]]
} >>"$log" 2>&1 || fail update-main "pushed $merged, but cannot fetch it into $repo"

if [[ -n $main_wt ]]; then
  [[ $(git -C "$repo" rev-parse refs/heads/main) == "$main_old" ]] ||
    fail update-main "pushed $merged, but local main moved during the push"
  git -C "$main_wt" merge --ff-only --quiet "$merged" >>"$log" 2>&1 ||
    fail update-main "pushed $merged, but cannot fast-forward main in $main_wt"
else
  git -C "$repo" update-ref -m "nix-land: merge $branch" refs/heads/main "$merged" "$main_old" ||
    fail update-main "pushed $merged, but local main moved during the landing"
fi

[[ $(git -C "$repo" rev-parse refs/heads/main) == "$merged" ]] ||
  fail update-main "main is not $merged after the update; something else moved it"

if [[ -z $switch ]]; then
  echo "LANDED $merged"
  exit 0
fi

# The switch request names this commit, and the service refuses it unless it is
# still main's head; the report must then name exactly this commit too.
[[ $(git -C "$repo" rev-parse refs/heads/main) == "$merged" ]] ||
  fail switch "main moved past $merged before the switch; nothing was switched"
say 'host-switch'
switch_out=$(host-switch --expect "$merged" 2>&1) || {
  printf '%s\n' "$switch_out" >>"$log"
  fail switch "host-switch failed for $merged: ${switch_out##*$'\n'}"
}
printf '%s\n' "$switch_out" >>"$log"
grep -qxF "host-switch: switched to $merged" <<<"$switch_out" ||
  fail switch "host-switch did not report switching $merged: ${switch_out##*$'\n'}"

if [[ -n $refresh ]]; then
  # The switch has just installed the refresh that knows the new sandbox image.
  refresher=/run/current-system/sw/bin/bot-sandbox-refresh
  [[ -x $refresher ]] || refresher=bot-sandbox-refresh
  "$refresher" >&2 || say 'bot-sandbox-refresh reported a problem; the landing itself succeeded'
fi

echo "LANDED $merged"
