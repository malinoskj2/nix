#!/usr/bin/env bash
set -euo pipefail

# Launch an agent harness in its own fresh instance of a named sandbox. Every
# invocation creates a new container from the sandbox image, so harnesses on
# the same service never share a runtime: the container lives exactly as long
# as its harness, the last harness to quit stops the sandbox, and the next
# launch starts from a fresh container. Only state mapped from the host (the
# persistent sandbox home, the shared directories) carries over.
if [[ $# -lt 1 ]]; then
  echo 'usage: agent-sandbox-exec <claude|codex|muse|zcode> [agent arguments...]' >&2
  exit 2
fi

agent=$1
shift
if [[ $agent != claude && $agent != codex && $agent != muse && $agent != zcode ]]; then
  echo "agent-sandbox-exec: unsupported agent: $agent" >&2
  exit 2
fi

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo 'agent-sandbox-exec: run this command inside a Git repository' >&2
  exit 2
fi
# Linked worktrees use the main repository's name, regardless of their directory.
git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
if [[ $(basename "$git_common_dir") == .git ]]; then
  repo_root=$(dirname "$git_common_dir")
fi
alias=sandbox-$(basename "$repo_root")
if [[ ! $alias =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "agent-sandbox-exec: invalid sandbox alias: $alias" >&2
  exit 2
fi

# Keep the agent-sandbox- prefix so agent-sandbox-kill's container filter
# still matches harness instances.
instance=agent-sandbox-$alias-h$$-$RANDOM
echo "agent-sandbox-exec: starting instance $instance" >&2

# The bridge is private to this agent launch. Orca still listens only on the
# desktop loopback; the container sees a Unix socket under its bind-mounted
# runtime directory. Its curl shim uses that socket only for Orca hook URLs.
if [[ -n ${ORCA_PANE_KEY:-} && -n ${ORCA_AGENT_HOOK_PORT:-} && -n ${ORCA_AGENT_HOOK_TOKEN:-} ]]; then
  relay_root=/run/user/$(id -u)/agent-sandbox-orca
  sandbox_home=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/home
  "$AGENT_SANDBOX_PREPARE_ORCA_HOOKS" "$HOME" "$sandbox_home"

  relay_dir=$(mktemp -d "$relay_root/session.XXXXXXXX")
  chmod 700 "$relay_dir"
  proxy_socket=$relay_dir/hook.sock
  cleanup() {
    if [[ -n ${proxy_pid:-} ]]; then
      kill "$proxy_pid" 2>/dev/null || true
      wait "$proxy_pid" 2>/dev/null || true
    fi
    rm -f -- "$proxy_socket" "$relay_dir/proxy.log"
    rmdir -- "$relay_dir"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$AGENT_SANDBOX_HOOK_PROXY" "$proxy_socket" "${ORCA_AGENT_HOOK_ENDPOINT:-}" \
    "$ORCA_AGENT_HOOK_PORT" >"$relay_dir/proxy.log" 2>&1 &
  proxy_pid=$!
  for _ in $(seq 100); do
    [[ -S $proxy_socket ]] && break
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      echo "agent-sandbox-exec: Orca hook bridge failed" >&2
      cat "$relay_dir/proxy.log" >&2
      exit 1
    fi
    sleep 0.02
  done
  if [[ ! -S $proxy_socket ]]; then
    echo "agent-sandbox-exec: timed out starting Orca hook bridge" >&2
    exit 1
  fi
  # The launcher forwards this to the container and switches its PATH to the
  # Orca curl shim so hook URLs reach the desktop through the relay.
  export ORCA_AGENT_HOOK_SOCKET=$proxy_socket
fi

AGENT_SANDBOX_NAME=$instance "$AGENT_SANDBOX_LAUNCHER" "--$agent" "$@"
