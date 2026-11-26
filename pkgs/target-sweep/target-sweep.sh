# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: target-sweep [--dry-run] [--days <n>]

Remove the Cargo target directories (those holding CACHEDIR.TAG) of linked
worktrees of every Orca git project that have been idle for <n> days (default
14). A worktree is idle when Orca shows no activity, live terminal or unfinished
agent in it for that long, its git index hasn't changed, and nothing in the
target directory was built in that time. Main checkouts and bot homes are never
touched, and nothing is removed when Orca can't be read. Prints what it frees
and records the summary in $XDG_STATE_HOME/target-sweep/last.
USAGE
}

dry_run='' days=14
while (($#)); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --days)
      (($# >= 2)) && [[ $2 =~ ^[0-9]+$ ]] || {
        usage >&2
        exit 2
      }
      days=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

orca=${ORCA_CLI_COMMAND:-orca-ide}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/target-sweep
cutoff=$(($(date +%s) - days * 86400))

if ! repos=$("$orca" repo list --json 2>/dev/null) || ! ps=$("$orca" worktree ps --json --limit 1000 2>/dev/null); then
  echo 'target-sweep: cannot read Orca; nothing removed' >&2
  exit 1
fi

# Prints why the worktree is active, or nothing when it is idle.
active_reason() {
  local wt=$1 index
  jq -r --arg p "$wt" --argjson cutoff "$cutoff" '
    [.result.worktrees[] | select(.path == $p)][0] // empty
    | if .isMainWorktree or .botHome then "main checkout or bot home"
      elif (.liveTerminalCount // 0) > 0 then "live terminal"
      elif any(.agents[]?; .state != "done") then "agent not done"
      elif ((.lastActivityAt // 0) / 1000) >= $cutoff then "Orca activity"
      else empty end' <<<"$ps"
  index=$(git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null) || {
    echo 'not a git worktree'
    return
  }
  if [[ -e $index ]] && (($(stat -c %Y "$index") >= cutoff)); then
    echo 'recent git activity'
  fi
  return 0
}

total=0 count=0
lines=()
while IFS=$'\t' read -r repo; do
  [[ -d $repo ]] || continue
  mapfile -t worktrees < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
  for wt in "${worktrees[@]}"; do
    [[ -d $wt && $wt != "$repo" ]] || continue
    reason=$(active_reason "$wt")
    [[ -z $reason ]] || continue
    while IFS= read -r -d '' tag; do
      target=${tag%/CACHEDIR.TAG}
      [[ -z $(git -C "$wt" ls-files -- "${target#"$wt"/}" | head -n 1) ]] || continue
      if [[ -n $(find "$target" -maxdepth 2 -newermt "@$cutoff" -print -quit) ]]; then
        continue
      fi
      size=$(du -sb -- "$target" | cut -f1)
      if [[ -z $dry_run ]]; then
        rm -rf -- "$target" || {
          echo "target-sweep: cannot remove $target" >&2
          continue
        }
      fi
      total=$((total + size))
      count=$((count + 1))
      lines+=("$(numfmt --to=iec --suffix=B "$size") $target")
    done < <(find "$wt" -maxdepth 4 \( -name .git -o -name node_modules -o -name .tmp \) -prune -o \
      -type f -name CACHEDIR.TAG -path '*/target/CACHEDIR.TAG' -print0 2>/dev/null)
  done
done < <(jq -r '.result.repos[] | select(.kind == "git") | .path' <<<"$repos")

verb=freed
[[ -z $dry_run ]] || verb='would free'
summary="$(date '+%F %T') $verb $(numfmt --to=iec --suffix=B "$total") from $count target dir(s) idle ${days}+ days"
((${#lines[@]} == 0)) || printf '%s\n' "${lines[@]}"
echo "$summary"
if [[ -z $dry_run ]]; then
  mkdir -p "$state_dir"
  echo "$summary" >"$state_dir/last"
fi
