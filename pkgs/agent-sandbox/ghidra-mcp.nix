{
  # Opt in for reverse-engineering sessions with -c mcp_servers.ghidra.enabled=true.
  enabled = false;
  # Ghidra's JVM starts before the server answers, and decompiling large functions is slow.
  startup_timeout_sec = 30;
  tool_timeout_sec = 300;
}
