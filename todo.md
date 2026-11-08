# Future investigation: lazy MCP connections

Goal: keep optional MCP tools discoverable in Codex and Claude Code without
connecting to their servers at session startup. An agent should be able to start
Unreal later and use its MCP tools in the same conversation, without startup
warnings when the editor is closed.

- Investigate Claude Code's native `MCP_DISCOVERY_CACHE=1` behavior for HTTP/SSE
  servers. Documentation says a previously cached tool catalog allows connection
  on first use: https://code.claude.com/docs/en/mcp#server-status-detail
- Recheck Codex's native capabilities. Its documented
  `startup_readiness = "catalog"` permits cached tools while connecting in the
  background; confirm whether a true connect-on-first-use option becomes available:
  https://learn.chatgpt.com/docs/extend/mcp?surface=cli
- Evaluate existing community solutions before writing an adapter:
  - https://github.com/sleticalboy/lazy-mcp-wrapper (stdio and Streamable HTTP)
  - https://github.com/tkukushkin/lazy-mcp (stdio)
- Test cold and warm caches, editor closed at agent startup, editor started later,
  editor restarts, stale tool catalogs, and recovery after failed calls. Check
  resources and prompts do not unexpectedly trigger startup connections.
- Prefer native harness support where possible. Evaluate maintenance, isolation,
  authentication, and Nix packaging before adopting a general wrapper.

Current state: Unreal MCP is disabled by default in Codex. After starting the
editor, opt in with `codex -c mcp_servers.unreal-mcp.enabled=true`.
No lazy wrapper has been installed or tested locally.
Ghidra MCP is also disabled by default in Codex; opt in with
`codex -c mcp_servers.ghidra.enabled=true`. Claude Code no longer registers
Ghidra MCP by default.
