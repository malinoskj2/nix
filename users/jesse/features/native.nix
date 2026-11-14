{ lib, pkgs, ... }:
let
  ghidraMcp = import ../../../pkgs/agent-sandbox/ghidra-mcp.nix;
in
{
  home.packages = with pkgs; [
    clang
    ghidra
    gitleaks
    last30days
    lldb
    media-transcribe
    mold
    yt-dlp
  ];

  programs.codex.settings.mcp_servers.ghidra = ghidraMcp // {
    command = lib.getExe pkgs.pyghidra-mcp;
  };
}
