_:
let
  mcp = import ../../../pkgs/agent-sandbox/unreal-mcp.nix;
in
{
  programs.claude-code.mcpServers.unreal-mcp = {
    type = "http";
    inherit (mcp) url;
  };
  programs.codex.settings.mcp_servers.unreal-mcp = {
    inherit (mcp) url;
    startup_timeout_sec = 30;
    tool_timeout_sec = 120;
  };
  home.file.".zcode/cli/config.json".text = builtins.toJSON {
    mcp.servers.unreal-mcp = {
      type = "http";
      inherit (mcp) url;
      enabled = true;
      timeoutMs = 120000;
    };
  };
}
