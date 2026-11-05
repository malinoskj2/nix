#!/usr/bin/env bash

if [[ $# -lt 1 ]]; then
  echo 'usage: agent-sandbox-resume <claude|codex|muse> [agent arguments...]' >&2
  exit 2
fi

agent=$1
shift
sandbox_home=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/home

session=
previous=
for arg in "$@"; do
  if [[ $previous == resume || $previous == --resume ]]; then
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
    muse) [[ -n $session ]] && compgen -G "$sandbox_home/.local/share/muse/sessions/*/*/*/$session" >/dev/null ;;
    *) return 1 ;;
  esac
}

# agent-sandbox-exec names its sandbox after the Git repository it runs in.
if ! started_in_sandbox || ! git rev-parse --show-toplevel >/dev/null 2>&1; then
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
