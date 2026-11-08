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

  programs.codex.settings.mcp_servers.ghidra = ghidraMcp // {
    command = lib.getExe pkgs.pyghidra-mcp;
  };
}
