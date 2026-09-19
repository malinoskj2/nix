#!/usr/bin/env bash

input=$(cat)
[[ $(jq -r '.tool_input.status // empty' <<<"$input") == completed ]] || exit 0

id=$(jq -r '.tool_input.taskId' <<<"$input")
session=$(jq -r '.session_id' <<<"$input")
list=${CLAUDE_CODE_TASK_LIST_ID:-session-${session:0:8}}
dir=$HOME/.claude/tasks/$list
archive=$HOME/.claude/tasks-archive/$list

[[ -f $dir/$id.json ]] || exit 0
mkdir -p "$archive"
mv "$dir/$id.json" "$archive/"

# Claude Code numbers new tasks from the files it can see, so without this an
# archived ID would be handed out again.
mark=$(cat "$dir/.highwatermark" 2>/dev/null || echo 0)
if ((id > mark)); then
  printf %s "$id" >"$dir/.highwatermark"
fi

# A missing task still counts as an open blocker.
for task in "$dir"/*.json; do
  [[ -f $task ]] || continue
  jq --arg id "$id" '.blockedBy -= [$id] | .blocks -= [$id]' "$task" >"$task.tmp"
  mv "$task.tmp" "$task"
done
