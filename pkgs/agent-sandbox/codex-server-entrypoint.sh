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

exec "$CODEX" "${overrides[@]}" app-server --listen "unix:///tmp/codex-daemon-$(id -u)/app-server.sock"
