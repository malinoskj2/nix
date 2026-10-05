#!/usr/bin/env bash

# Orca's POSIX hook scripts use curl against 127.0.0.1. For direct sandbox
# agents only, send those exact hook URLs over the private Unix socket instead.
if [[ -n ${ORCA_AGENT_HOOK_SOCKET:-} && -n ${ORCA_AGENT_HOOK_PORT:-} ]]; then
  for arg in "$@"; do
    case $arg in
      "http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/"* | \
        "http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/statusline/claude")
        exec "$AGENT_SANDBOX_REAL_CURL" --unix-socket "$ORCA_AGENT_HOOK_SOCKET" "$@"
        ;;
    esac
  done
fi
exec "$AGENT_SANDBOX_REAL_CURL" "$@"
