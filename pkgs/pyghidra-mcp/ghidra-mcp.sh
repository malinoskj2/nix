#!/usr/bin/env bash
set -euo pipefail

# Ghidra locks an open project, so each concurrent session in the same
# directory takes the next free slot; slots keep their analysis between runs.
directory_hash=$(printf %s "$PWD" | sha256sum | cut -c1-8)
root=${XDG_CACHE_HOME:-$HOME/.cache}/pyghidra-mcp/$(basename "$PWD")-$directory_hash
for ((slot = 1; ; slot++)); do
  project=$root/$slot
  mkdir -p "$project"
  exec 9>"$project/session.lock"
  if flock -n 9; then
    break
  fi
done

exec @pyghidra-mcp@ --project-path "$project" --project-name project "$@"
