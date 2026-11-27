#!/usr/bin/env bash

# The sandbox wrapper adds Ghidra and full access, so this runs Codex itself. It only generates
# images, so it starts none of the MCP servers the sandbox's config.toml names.
if [[ ${AGENT_SANDBOX_EGRESS:-} == 1 ]]; then
  socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/agent-egress/proxy.sock &
fi

overrides=()
while read -r name; do
  overrides+=(-c "mcp_servers.$name.enabled=false")
done < <("$CODEX" mcp list --json | jq -r '.[].name')

# Defaults only: a client can still ask a thread for more, which reaches no further than the
# sandbox asking, since this server shares the sandbox home and network. A requirements.toml
# that enforced read-only made Codex 0.171 fail every model request.
exec "$CODEX" "${overrides[@]}" -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' app-server --listen "unix:///tmp/codex-daemon-$(id -u)/app-server.sock"
