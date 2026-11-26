# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: bot-sandbox-refresh [--dry-run]

Stop the sandbox containers of idle Orca bots (agent-sandbox-sandbox-bot-<name>-*)
that run an older image than the current agent-sandbox one, so each bot's next
message relaunches it, session resumed, on the new image. A bot is idle when
`orca worktree ps` shows every workspace under its home with no working agent
and every agent there done. Busy bots and bots Orca can't report on are skipped.
Prints one line per bot: restarted, skipped or current.
USAGE
}

dry_run=''
case ${1:-} in
  '') ;;
  --dry-run) dry_run=1 ;;
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
bots_dir=${BOT_SANDBOX_REFRESH_BOTS:-$HOME/.orca/bots}
current=${AGENT_SANDBOX_IMAGE_REF:?}

declare -A containers=()
while read -r name image; do
  [[ $name =~ ^agent-sandbox-sandbox-bot-(.+)-h[0-9]+-[0-9]+$ ]] || continue
  bot=${BASH_REMATCH[1]}
  if [[ $image == "$current" ]]; then
    containers[$bot]+=''
  else
    containers[$bot]+="$name "
  fi
done < <(docker ps --filter name=^agent-sandbox-sandbox-bot- --format '{{.Names}} {{.Image}}')

if ((${#containers[@]} == 0)); then
  echo 'bot-sandbox-refresh: no bot sandboxes running'
  exit 0
fi

# Prints why the bot isn't idle, or nothing when it is.
busy_reason() {
  local home=$bots_dir/$1 ps
  ps=$("$orca" worktree ps --json --limit 1000 2>/dev/null) || {
    echo 'orca worktree ps failed'
    return
  }
  jq -r --arg home "$home" '
    [.result.worktrees[] | select(.path == $home or (.path | startswith($home + "/")))] as $rows
    | if ($rows | length) == 0 then "Orca lists no workspace for it"
      elif any($rows[]; .status == "working") then "working"
      else ([$rows[].agents[] | select(.state != "done") | .state] | unique | join(",")) as $s
        | if $s == "" then empty else "agent " + $s end
      end' <<<"$ps" 2>/dev/null || echo 'cannot read orca worktree ps'
}

status=0
for bot in $(printf '%s\n' "${!containers[@]}" | sort); do
  read -ra stale <<<"${containers[$bot]}"
  if ((${#stale[@]} == 0)); then
    echo "current $bot"
    continue
  fi
  reason=$(busy_reason "$bot")
  if [[ -n $reason ]]; then
    echo "skipped $bot ($reason)"
    continue
  fi
  if [[ -n $dry_run ]]; then
    echo "would restart $bot (${stale[*]})"
    continue
  fi
  # The containers run with --rm, so a stop removes them; Orca relaunches the bot on its next message.
  if docker stop --time 30 "${stale[@]}" >/dev/null; then
    echo "restarted $bot (${#stale[@]} container(s))"
  else
    echo "failed $bot (docker stop)"
    status=1
  fi
done
exit "$status"
