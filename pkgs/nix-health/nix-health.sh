# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: nix-health [--precheck]

Check home's health: failed system and user units, free disk on /, /home,
/mnt/ext-ssd and the model stores, Orca workers stuck or stopped without
worker_done, Orca workspaces with no activity for 3 days, and dirty or
off-branch main checkouts (main-checkout-report). Prints only problems,
then the disk, sccache and last target-sweep numbers, then HEALTHY or
UNHEALTHY <sections with problems> as the last line. Exits 0 when healthy, 1
when not.

  --precheck  for an Orca automation precheck: print nothing, exit 0 when there
              is something to report (or the check itself failed), 1 when healthy

Environment: NIX_HEALTH_MIN_FREE_GIB (default 50), NIX_HEALTH_MAX_USE_PCT
(default 90), NIX_HEALTH_STALE_DAYS (default 3), NIX_HEALTH_STUCK_HOURS
(default 24), NIX_HEALTH_LONG_LIVED (workspace names never reported as stale).
USAGE
}

case ${1:-} in
  '') ;;
  --precheck)
    # A crashed check is something to report too, never a silent skip.
    status=0
    "${BASH_SOURCE[0]}" >/dev/null 2>&1 || status=$?
    ((status != 0)) || exit 1
    exit 0
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

orca=${ORCA_CLI_COMMAND:-orca-ide}
min_free_gib=${NIX_HEALTH_MIN_FREE_GIB:-50}
max_use_pct=${NIX_HEALTH_MAX_USE_PCT:-90}
stale_days=${NIX_HEALTH_STALE_DAYS:-3}
stuck_hours=${NIX_HEALTH_STUCK_HOURS:-24}
long_lived=${NIX_HEALTH_LONG_LIVED:-}
model_root=${MODEL_ROOT:-/mnt/ext-ssd/models}
model_stores=${NIX_HEALTH_MODEL_STORES:-$HOME/.local/share/model-stores/install}

problems=0
section() {
  local title=$1 body=$2
  [[ -n $body ]] || return 0
  printf '## %s\n%s\n\n' "$title" "$body"
  problems=$((problems + 1))
}

units() {
  if ! command -v systemctl >/dev/null; then
    echo 'cannot check: systemctl is missing'
    return
  fi
  local scope
  for scope in system user; do
    local args=(--failed --no-legend --plain)
    [[ $scope == user ]] && args+=(--user)
    local out
    if ! out=$(systemctl "${args[@]}" 2>&1); then
      echo "cannot list failed $scope units: ${out%%$'\n'*}"
      continue
    fi
    awk -v s="$scope" 'NF {print s ": " $1}' <<<"$out"
  done
}

disks() {
  local path
  for path in / /home /mnt/ext-ssd "$model_root" "$model_stores"; do
    if [[ ! -d $path ]]; then
      echo "$path: missing"
      continue
    fi
    # shellcheck disable=SC2034
    read -r _ size used avail pct _ < <(df -P -B1G "$path" | tail -n 1)
    pct=${pct%\%}
    if ((avail < min_free_gib || pct > max_use_pct)); then
      echo "$path: ${avail} GiB free of ${size} GiB (${pct}% used)"
    fi
  done
}

workers() {
  local state cursor page now
  now=$(date +%s)
  local rows=()
  for state in active reclaimable retained release_pending release_unknown; do
    cursor=''
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      local args=(orchestration worker-list --terminal-state "$state" --limit 100 --json --full)
      [[ -n $cursor ]] && args+=(--cursor "$cursor")
      if ! page=$("$orca" "${args[@]}" 2>/dev/null) || [[ $(jq -r .ok <<<"$page") != true ]]; then
        echo "cannot list $state workers"
        break
      fi
      rows+=("$(jq -c '.result.workers[]' <<<"$page")")
      cursor=$(jq -r '.result.nextCursor // empty' <<<"$page")
      [[ -n $cursor ]] || break
    done
  done
  local all
  all=$(printf '%s\n' "${rows[@]}" | jq -sc 'map(select(. != null)) | unique_by(.dispatchId)')
  jq -r '.[] | .projection as $p
    | ($p.workspace.id // "" | split("::") | last) as $where
    | if $p.outcome == "in_progress" and $p.liveness.verdict != "live" then
        "\(.dispatchId) \(.taskId) in \($where): stopped (\($p.liveness.verdict)) without worker_done"
      elif $p.outcome == "failed" and (($p.attention.categories // []) | index("interruption")) then
        "\(.dispatchId) \(.taskId) in \($where): interrupted without worker_done, terminal \(.terminalState)"
      elif $p.outcome == "in_progress" and ($p.stage.activity // "") != "working" then
        "\(.dispatchId) \(.taskId) in \($where): live but \($p.stage.activity // "idle") without worker_done"
      else empty end' <<<"$all"
  # Long-running live workers: their task's age, read from its Run.
  local run task created
  while read -r run task where; do
    created=$("$orca" orchestration task-list --run "$run" --json 2>/dev/null |
      jq -r --arg t "$task" '.result.tasks[]? | select(.id == $t) | .created_at // empty')
    [[ -n $created ]] || continue
    created=$(date -d "${created/ /T}Z" +%s 2>/dev/null) || continue
    if ((now - created > stuck_hours * 3600)); then
      echo "$task in $where: still in progress after $(((now - created) / 3600)) h"
    fi
  done < <(jq -r '.[] | .projection as $p
    | select($p.outcome == "in_progress" and $p.liveness.verdict == "live" and $p.stage.activity == "working")
    | "\(.runId) \(.taskId) \($p.workspace.id // "" | split("::") | last)"' <<<"$all")
}

stale() {
  local ps
  if ! ps=$("$orca" worktree ps --json --limit 1000 2>/dev/null); then
    echo 'cannot run orca worktree ps'
    return
  fi
  jq -r --argjson days "$stale_days" --arg keep "$long_lived" '
    ($keep | split(" ") | map(select(. != ""))) as $keep
    | (now * 1000 - $days * 86400000) as $cutoff
    | .result.worktrees[]
    | select((.isMainWorktree | not) and (.botHome | not) and (.isArchived | not) and (.isPinned | not))
    | select((.displayName as $n | $keep | index($n)) | not)
    | select((.lastActivityAt // .createdAt // 0) < $cutoff)
    | "\(.repo)/\(.displayName): no activity since \((.lastActivityAt // .createdAt) / 1000 | strflocaltime("%F"))"' <<<"$ps"
}

disk_numbers() {
  local path dir size
  for path in / /home /mnt/ext-ssd "$model_root" "$model_stores"; do
    [[ -d $path ]] || continue
    df -P -B1G "$path" | awk -v p="$path" 'NR == 2 {printf "%s: %s GiB free of %s GiB (%s used)\n", p, $4, $2, $5}'
  done
  for dir in "$HOME/.cache/sccache" "${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/home/.cache/sccache"; do
    [[ -d $dir ]] || continue
    size=$(timeout 120 du -sh -- "$dir" 2>/dev/null | cut -f1) || size=unknown
    echo "sccache $dir: $size"
  done
  local sweep=${XDG_STATE_HOME:-$HOME/.local/state}/target-sweep/last
  if [[ -r $sweep ]]; then
    echo "last target-sweep: $(<"$sweep")"
  else
    echo 'last target-sweep: never'
  fi
}

checkouts() {
  local out status=0
  out=$(main-checkout-report 2>&1) || status=$?
  case $status in
    0) ;;
    1) printf '%s\n' "$out" ;;
    *) echo "main-checkout-report failed: ${out%%$'\n'*}" ;;
  esac
}

section 'Failed units' "$(units)"
section 'Low disk' "$(disks)"
section 'Orca workers' "$(workers)"
section "No activity for $stale_days days" "$(stale)"
section 'Main checkouts' "$(checkouts)"

printf '## Disk\n%s\n\n' "$(disk_numbers)"
if ((problems)); then
  echo "UNHEALTHY $problems"
  exit 1
fi
echo HEALTHY
