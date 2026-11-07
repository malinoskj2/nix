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
}
