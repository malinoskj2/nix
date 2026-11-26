#!/usr/bin/env bash

launcher_args=()
if [[ ${1:-} == --display ]]; then
  launcher_args+=(--display)
  shift
fi

if [[ $# -lt 1 ]]; then
  echo 'usage: agent-sandbox-exec [--display] <claude|codex|antigravity|opencode> [agent arguments...]' >&2
  exit 2
fi

agent=$1
shift
# Orca names Antigravity's harness after the product; its command is agy.
if [[ $agent == agy ]]; then
  agent=antigravity
fi
if [[ $agent != claude && $agent != codex && $agent != antigravity && $agent != opencode ]]; then
  echo "agent-sandbox-exec: unsupported agent: $agent" >&2
  exit 2
fi

bot_status=0
bot_home=$(agent-sandbox-bot-home) || bot_status=$?

if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  # Linked worktrees use the main repository's name, regardless of their directory.
  git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
  if [[ $(basename "$git_common_dir") == .git ]]; then
    repo_root=$(dirname "$git_common_dir")
  fi
  alias=sandbox-$(basename "$repo_root")
elif [[ $bot_status == 0 ]]; then
  # Orca bots chat from their home, outside Git, and each keeps its own sandbox.
  # This wins over the chat account path, which every Codex chat sets.
  alias=sandbox-bot-${bot_home%%$'\n'*}
  cd "${bot_home#*$'\n'}" || exit 2
elif [[ $bot_status == 2 ]]; then
  exit 2
elif [[ $agent == codex && -n ${CODEX_HOME:-} ]] ||
  [[ $agent == claude && -n ${CLAUDE_CONFIG_DIR:-} ]]; then
  # Chat's model/account probes run from its account directory, outside Git.
  # They still need the sandbox and the selected account, never a host fallback.
  alias=sandbox-$agent-chat
else
  echo 'agent-sandbox-exec: run this command inside a Git repository' >&2
  exit 2
fi

if [[ ! $alias =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "agent-sandbox-exec: invalid sandbox alias: $alias" >&2
  exit 2
fi

# Keep the agent-sandbox- prefix so agent-sandbox-kill's container filter
# still matches harness instances.
instance=agent-sandbox-$alias-h$$-$RANDOM
echo "agent-sandbox-exec: starting instance $instance" >&2

finish_launch() {
  if [[ -n ${ORCA_PANE_KEY:-} && -z ${ORCA_STRUCTURED_SESSION:-} ]]; then
    printf '\033]777;orca-container;clear\033\134' >&2
  fi
  if [[ -n ${relay_dir:-} ]]; then
    stop_hook_bridge
  fi
}
trap finish_launch EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

stop_hook_bridge() {
  if [[ -n ${proxy_pid:-} ]]; then
    kill "$proxy_pid" 2>/dev/null || true
    wait "$proxy_pid" 2>/dev/null || true
  fi
  rm -f -- "${proxy_socket:-}" "$relay_dir/proxy.log"
  rmdir -- "$relay_dir"
}

# The bridge is private to this agent launch. Orca still listens only on the
# desktop loopback; the container sees a Unix socket under its bind-mounted
# runtime directory. Its curl shim uses that socket only for Orca hook URLs.
start_hook_bridge() {
  local relay_root container_codex_home host_codex_home sandbox_home
  relay_root=/run/user/$(id -u)/agent-sandbox-orca
  sandbox_home=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox/home
  "$AGENT_SANDBOX_PREPARE_ORCA_HOOKS" "$HOME" "$sandbox_home"

  mkdir -p "$relay_root"
  chmod 700 "$relay_root"
  relay_dir=$(mktemp -d "$relay_root/session.XXXXXXXX")
  chmod 700 "$relay_dir"
  proxy_socket=$relay_dir/hook.sock
  # Explicit accounts are bind-mounted at the same path. Without CODEX_HOME,
  # Codex writes into the sandbox's private home, which Orca cannot see there.
  container_codex_home=${CODEX_HOME:-$HOME/.codex}
  host_codex_home=${CODEX_HOME:-$sandbox_home/.codex}
  # Orca reads agy's transcripts to tell its root conversation, the one it resumes, from subagents.
  "$AGENT_SANDBOX_HOOK_PROXY" "$proxy_socket" "${ORCA_AGENT_HOOK_ENDPOINT:-}" \
    "$ORCA_AGENT_HOOK_PORT" "$container_codex_home" "$host_codex_home" \
    "$HOME/.gemini" "$sandbox_home/.gemini" >"$relay_dir/proxy.log" 2>&1 &
  proxy_pid=$!
  for _ in {1..100}; do
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
}

if [[ -n ${ORCA_PANE_KEY:-} && -n ${ORCA_AGENT_HOOK_PORT:-} && -n ${ORCA_AGENT_HOOK_TOKEN:-} ]]; then
  start_hook_bridge
fi

AGENT_SANDBOX_NAME=$instance "$AGENT_SANDBOX_LAUNCHER" "${launcher_args[@]}" "--$agent" "$@"
