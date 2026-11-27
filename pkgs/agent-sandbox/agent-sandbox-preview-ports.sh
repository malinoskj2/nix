#!/usr/bin/env bash

# Prints the first of the five host ports a sandbox identity keeps for its previews. Each
# identity gets a slot from its hash, the next free one on a collision, and keeps it in the
# state file, so restarts and refreshes give it the same links.

if [[ $# -ne 1 || -z $1 || $1 == *$'\t'* || $1 == *$'\n'* ]]; then
  echo 'usage: agent-sandbox-preview-ports <identity>' >&2
  exit 2
fi
identity=$1
state=${AGENT_SANDBOX_PREVIEW_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/preview-ports}
base=${AGENT_SANDBOX_PREVIEW_BASE:-19000}
slots=${AGENT_SANDBOX_PREVIEW_SLOTS:-400}

mkdir -p "$(dirname "$state")"
exec 8>"$state.lock"
flock 8

declare -A owner=()
kept=()
found=
if [[ -f $state ]]; then
  while IFS=$'\t' read -r slot name; do
    if [[ ! $slot =~ ^[0-9]+$ || -z $name ]] || ((slot >= slots)) || [[ -n ${owner[$slot]:-} ]]; then
      continue
    fi
    # A worktree that no longer exists gives its slot back.
    if [[ $name == /* && ! -d $name ]]; then
      continue
    fi
    owner[$slot]=$name
    kept+=("$slot"$'\t'"$name")
    if [[ $name == "$identity" ]]; then
      found=$slot
    fi
  done <"$state"
fi

if [[ -z $found ]]; then
  hash=$(printf '%s' "$identity" | sha256sum | cut -c1-8)
  slot=$((16#$hash % slots))
  for ((i = 0; i < slots; i++)); do
    if [[ -z ${owner[$slot]:-} ]]; then
      found=$slot
      break
    fi
    slot=$(((slot + 1) % slots))
  done
  if [[ -z $found ]]; then
    echo 'agent-sandbox-preview-ports: every slot is taken' >&2
    exit 1
  fi
  kept+=("$found"$'\t'"$identity")
fi

printf '%s\n' "${kept[@]}" >"$state.new"
mv -f -- "$state.new" "$state"
echo $((base + found * 5))
