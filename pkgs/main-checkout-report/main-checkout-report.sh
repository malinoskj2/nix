# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: main-checkout-report

List every Orca git project's main checkout (orca repo list) that has
uncommitted or untracked changes or isn't on its default branch, with what
last touched it: the newest reflog entry, the newest changed file, and the
latest Orca agent seen in that checkout. Changes nothing. Prints nothing and
exits 0 when every checkout is clean; exits 1 when it lists any, 2 when it
can't read Orca's projects.
USAGE
}

case ${1:-} in
  '') ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

orca=${ORCA_CLI_COMMAND:-orca-ide}

repos=$("$orca" repo list --json 2>/dev/null) || {
  echo 'main-checkout-report: orca repo list failed' >&2
  exit 2
}
agents=$("$orca" agent list --json 2>/dev/null || echo '{}')

default_branch() {
  local path=$1 base=$2 ref
  if [[ -n $base ]]; then
    base=${base#refs/heads/}
    base=${base#refs/remotes/}
    base=${base#origin/}
    echo "$base"
    return
  fi
  if ref=$(git -C "$path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${ref#origin/}"
    return
  fi
  for ref in main master; do
    if git -C "$path" show-ref --verify --quiet "refs/heads/$ref"; then
      echo "$ref"
      return
    fi
  done
}

found=0
while IFS=$'\t' read -r id name path base; do
  if [[ ! -d $path ]]; then
    printf '%s (%s): checkout missing\n' "$name" "$path"
    found=1
    continue
  fi
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
  want=$(default_branch "$path" "$base")
  have=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached at $(git -C "$path" rev-parse --short HEAD)")
  changes=$(git -C "$path" status --porcelain 2>/dev/null)
  problems=()
  if [[ -n $want && $have != "$want" ]]; then
    problems+=("on $have, not $want")
  fi
  if [[ -n $changes ]]; then
    tracked=$(grep -vc '^??' <<<"$changes" || true)
    untracked=$(grep -c '^??' <<<"$changes" || true)
    problems+=("$tracked changed, $untracked untracked")
  fi
  ((${#problems[@]})) || continue
  found=1
  summary=${problems[0]}
  for problem in "${problems[@]:1}"; do summary+="; $problem"; done
  printf '%s (%s): %s\n' "$name" "$path" "$summary"

  reflog=$(git -C "$path" reflog -1 --date=iso --format='%gd %gs' HEAD 2>/dev/null | sed 's/^HEAD@{\([^}]*\)}/\1/')
  if [[ -n $reflog ]]; then
    printf '  last git action: %s\n' "$reflog"
  fi
  if [[ -n $changes ]]; then
    newest=$(cut -c4- <<<"$changes" | sed 's/.* -> //; s/^"//; s/"$//' | while read -r file; do
      if [[ -e $path/$file ]]; then
        stat -c '%Y %n' -- "$path/$file"
      fi
    done | sort -rn | head -n 1)
    if [[ -n $newest ]]; then
      printf '  newest change: %s at %s\n' "${newest#* "$path"/}" "$(date -d "@${newest%% *}" '+%F %T')"
    fi
  fi
  agent=$(jq -r --arg wt "$id::$path" '
    [.result.agents[]? | select(.worktreeId == $wt)] | max_by(.updatedAt) // empty
    | "\(.agent) \(.kind) \(.orcaSessionId) (\(.state), \(.updatedAt / 1000 | strflocaltime("%F %T")))"' <<<"$agents" 2>/dev/null)
  if [[ -n $agent ]]; then
    printf '  last Orca agent there: %s\n' "$agent"
  fi
done < <(jq -r '.result.repos[] | select(.kind == "git") | [.id, .displayName, .path, (.worktreeBaseRef // "")] | @tsv' <<<"$repos")

exit "$found"
