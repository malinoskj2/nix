{ lib, pkgs, ... }:
let
  ghidraMcp = import ../../../pkgs/agent-sandbox/ghidra-mcp.nix;
in
{
  home.packages = with pkgs; [
    clang
    ghidra
    gitleaks
    lldb
    mold
  ];

  programs.claude-code.mcpServers.ghidra.command = lib.getExe pkgs.pyghidra-mcp;
  programs.codex.settings.mcp_servers.ghidra = ghidraMcp // {
    command = lib.getExe pkgs.pyghidra-mcp;
  };
}
