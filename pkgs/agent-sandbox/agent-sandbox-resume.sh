#!/usr/bin/env bash

if [[ $# -lt 1 ]]; then
  echo 'usage: agent-sandbox-resume <claude|codex|antigravity> [agent arguments...]' >&2
  exit 2
fi

agent=$1
shift
sandbox_home=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/home

session=
previous=
for arg in "$@"; do
  if [[ $previous == resume || $previous == --resume || $previous == --conversation ]]; then
    session=$arg
  fi
  previous=$arg
done

started_in_sandbox() {
  case $agent in
    # Claude's transcripts live in the ~/.claude/projects every sandbox shares, so any session
    # resumes there.
    claude) return 0 ;;
    codex) [[ -n $session ]] && compgen -G "$sandbox_home/.codex/sessions/*/*/*/rollout-*-$session.jsonl" >/dev/null ;;
    antigravity) [[ -n $session && $session != */* && -e $sandbox_home/.gemini/antigravity-cli/brain/$session ]] ;;
    *) return 1 ;;
  esac
}

host_bot() {
  local id
  id=$(jq -er '.id | strings' "$1/bot.json" 2>/dev/null) || return 1
  [[ " ${AGENT_SANDBOX_HOST_BOT_IDS:-} " == *" $id "* ]]
}

bot_status=0
bot_home=$(agent-sandbox-bot-home) || bot_status=$?
if [[ $bot_status == 2 ]]; then
  exit 2
fi

# Bots chat in their own sandbox with whatever account Orca selected, so where
# their transcript lives says nothing about where they ran. Only host bots resume
# on the host, and an unreadable bot.json keeps a bot in its sandbox.
if [[ $bot_status == 0 ]] && ! host_bot "$HOME/.orca/bots/${bot_home%%$'\n'*}"; then
  cd "${bot_home#*$'\n'}" || exit 2
# agent-sandbox-exec names any other sandbox after the Git repository it runs in.
elif ! started_in_sandbox || ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  if [[ $agent == antigravity ]]; then
    exec agy "$@"
  fi
  exec "$agent" "$@"
fi

# The launcher adds Codex's bypass flag itself, and Codex refuses it twice.
args=()
for arg in "$@"; do
  if [[ $agent == codex && $arg == --dangerously-bypass-approvals-and-sandbox ]]; then
    continue
  fi
  args+=("$arg")
done
exec agent-sandbox-exec "$agent" "${args[@]}"
