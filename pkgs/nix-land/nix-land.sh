# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: nix-land [--dry-run] [--no-switch] [--no-refresh] <branch>

Merge <branch> into main of the nix repository in a temporary worktree, run
`nix flake check` and rust-lints on any Rust the branch changes, push main
(through the Betterleaks push gate), move the local main, run host-switch and
then bot-sandbox-refresh.

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

wt=''
cleanup() {
  if [[ -n $wt && -d $wt ]]; then
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
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

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || fail preflight "$repo is not a git repository"
log_dir=$repo/.tmp/nix-land
mkdir -p "$log_dir" || fail preflight "cannot create $log_dir"
log=$log_dir/$(date +%Y%m%dT%H%M%S)-${branch//\//_}.log
: >"$log"

branch_sha=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch^{commit}") ||
  fail preflight "no local branch $branch"
main_old=$(git -C "$repo" rev-parse --verify --quiet 'refs/heads/main^{commit}') ||
  fail preflight 'no local main'

if [[ -z $dry_run ]]; then
  say "fetching origin/main"
  git -C "$repo" fetch --quiet origin main >>"$log" 2>&1 || fail preflight 'git fetch origin main failed'
  remote_main=$(git -C "$repo" rev-parse FETCH_HEAD)
  git -C "$repo" merge-base --is-ancestor "$remote_main" "$main_old" ||
    fail preflight "origin/main has commits local main lacks ($remote_main)"
fi

if git -C "$repo" merge-base --is-ancestor "$branch_sha" "$main_old"; then
  fail preflight "$branch is already in main"
fi
behind=$(git -C "$repo" rev-list --count "$branch_sha..$main_old")
say "$branch at ${branch_sha:0:12}, main at ${main_old:0:12}, branch is $behind commit(s) behind main"

wt=$(mktemp -d "${TMPDIR:-/tmp}/nix-land.XXXXXX")
rmdir "$wt"
git -C "$repo" worktree add --quiet --detach "$wt" "$main_old" >>"$log" 2>&1 ||
  fail preflight 'cannot create the temporary worktree'
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
  manifest=$(cargo locate-project --workspace --message-format plain --manifest-path "$dir/Cargo.toml" 2>>"$log") ||
    fail rust-lints "cannot resolve the Cargo workspace of $file"
  manifest=${manifest#"$wt"/}
  [[ " ${manifests[*]} " == *" $manifest "* ]] || manifests+=("$manifest")
done
for manifest in "${manifests[@]}"; do
  say "rust-lints on $manifest"
  lint_status=0
  rust-lints --manifest-path "$wt/$manifest" >>"$log" 2>&1 || lint_status=$?
  case $lint_status in
    0) ;;
    1) fail rust-lints "lint findings in $manifest" ;;
    *) fail rust-lints "$manifest failed to build or a lint tool failed: $(grep -m1 -E '^error' "$log" | cut -c1-200)" ;;
  esac
done
((${#manifests[@]})) || say 'no changed Rust'

say "nix flake check (log: $log)"
nix flake check --print-build-logs >>"$log" 2>&1 || fail flake-check "nix flake check failed: $(grep -m1 -E '^error' "$log" | cut -c1-200)"

if [[ -n $dry_run ]]; then
  say "dry run: not pushing $merged"
  echo "CHECKED $merged"
  exit 0
fi

main_wt=$(git -C "$repo" worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} $0=="branch refs/heads/main"{print w}')
if [[ -n $main_wt && -n $(git -C "$main_wt" status --porcelain --untracked-files=no) ]]; then
  fail update-main "main is checked out with uncommitted changes in $main_wt"
fi
[[ $(git -C "$repo" rev-parse refs/heads/main) == "$main_old" ]] || fail update-main 'local main moved during the checks; run nix-land again'

git -C "$repo" config --get hook.betterleaks-push-gate.event >/dev/null ||
  fail push 'the Betterleaks push gate is not configured for this git'

say "pushing $merged to origin/main"
git push origin "$merged:refs/heads/main" >>"$log" 2>&1 ||
  fail push "git push was refused (Betterleaks or the remote); see the log"

if [[ -n $main_wt ]]; then
  git -C "$main_wt" merge --ff-only --quiet "$merged" >>"$log" 2>&1 ||
    fail update-main "pushed $merged, but cannot fast-forward main in $main_wt"
else
  git -C "$repo" update-ref -m "nix-land: merge $branch" refs/heads/main "$merged" "$main_old" ||
    fail update-main "pushed $merged, but local main moved during the landing"
fi

if [[ -z $switch ]]; then
  echo "LANDED $merged"
  exit 0
fi

say 'host-switch'
host-switch >>"$log" 2>&1 || fail switch "host-switch failed for $merged: $(tail -n 1 "$log")"

if [[ -n $refresh ]]; then
  # The switch has just installed the refresh that knows the new sandbox image.
  refresher=/run/current-system/sw/bin/bot-sandbox-refresh
  [[ -x $refresher ]] || refresher=bot-sandbox-refresh
  "$refresher" >&2 || say 'bot-sandbox-refresh reported a problem; the landing itself succeeded'
fi

echo "LANDED $merged"
