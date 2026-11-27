_:
let
  unrealMcp = import ../../../pkgs/agent-sandbox/unreal-mcp.nix;
in
{
  programs.claude-code.mcpServers.unreal-mcp = {
    type = "http";
    inherit (unrealMcp) url;
  };
  programs.codex.settings.mcp_servers.unreal-mcp = {
    enabled = false;
    inherit (unrealMcp) url;
    startup_timeout_sec = 30;
    tool_timeout_sec = 120;
  };
  programs.opencode.settings.mcp.servers.unreal-mcp = {
    type = "remote";
    disabled = true;
    inherit (unrealMcp) url;
    oauth = false;
    timeout.execution = 120000;
  };
  programs.antigravity.mcpServers.unreal-mcp = {
    disabled = true;
    serverUrl = unrealMcp.url;
    timeoutSeconds = 120;
  };
}
