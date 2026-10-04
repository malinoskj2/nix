#!/usr/bin/env bash
set -euo pipefail

# Enter an existing sandbox from a local Orca terminal. Keep Orca's pane
# identity with the agent; docker exec otherwise starts with only the image env.
if [[ $# -lt 2 ]]; then
  echo 'usage: agent-sandbox-exec <sandbox alias> <claude|codex> [agent arguments...]' >&2
  exit 2
fi

alias=$1
agent=$2
shift 2
if [[ ! $alias =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "agent-sandbox-exec: invalid sandbox alias: $alias" >&2
  exit 2
fi
if [[ $agent != claude && $agent != codex ]]; then
  echo "agent-sandbox-exec: unsupported agent: $agent" >&2
  exit 2
fi

unit=agent-sandbox@$alias.service
container=agent-sandbox-$alias
if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
  systemctl --user start "$unit"
fi

# The service can be active before Docker creates its container. Match the
# SSH helper's bounded startup wait, without opening an SSH session.
for _ in $(seq 900); do
  if docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    break
  fi
  if ! systemctl --user --quiet is-active "$unit"; then
    echo "agent-sandbox-exec: $unit stopped; see journalctl --user -u $unit" >&2
    exit 1
  fi
  sleep 0.2
done
if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
  echo "agent-sandbox-exec: timed out waiting for $container" >&2
  exit 1
fi

args=(--interactive --workdir "$PWD")
if [[ -t 0 && -t 1 ]]; then
  args+=(--tty)
fi

# A local Orca PTY supplies these for the current pane. Forward only the
# specific fields agents and hook scripts use, not the host environment.
for name in \
  ORCA_PANE_KEY ORCA_TAB_ID ORCA_WORKTREE_ID ORCA_TERMINAL_HANDLE \
  ORCA_AGENT_LAUNCH_TOKEN ORCA_AGENT_HOOK_ENDPOINT \
  ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN ORCA_AGENT_HOOK_ENV \
  ORCA_AGENT_HOOK_VERSION ORCA_AGENT_HOOK_TRANSPORT TERM COLORTERM; do
  if [[ -v $name ]]; then
    args+=(--env "$name=${!name}")
  fi
done

# The bridge is private to this agent launch. Orca still listens only on the
# desktop loopback; the container sees a Unix socket under its bind-mounted
# runtime directory. Its curl shim uses that socket only for Orca hook URLs.
if [[ -n ${ORCA_PANE_KEY:-} && -n ${ORCA_AGENT_HOOK_PORT:-} && -n ${ORCA_AGENT_HOOK_TOKEN:-} ]]; then
  relay_root=/run/user/$(id -u)/agent-sandbox-orca
  if ! docker exec "$container" test -d "$relay_root"; then
    echo "agent-sandbox-exec: $container needs the updated runtime mount; recreate the sandbox" >&2
    exit 1
  fi
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
  args+=(--env "PATH=$AGENT_SANDBOX_ORCA_PATH" --env "ORCA_AGENT_HOOK_SOCKET=$proxy_socket")
fi

if [[ $agent == codex ]]; then
  set -- codex --dangerously-bypass-approvals-and-sandbox "$@"
else
  set -- claude "$@"
fi
docker exec "${args[@]}" "$container" "$@"
