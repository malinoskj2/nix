{ lib, pkgs, ... }:
let
  ghidraMcp = import ../../../pkgs/agent-sandbox/ghidra-mcp.nix;
in
{
  home.packages = with pkgs; [
    clang
    ghidra
    betterleaks-push-gate.betterleaks
    last30days
    lldb
    media-transcribe
    mold
    tiktok-search
    yt-dlp
  ];

  programs.codex.settings.mcp_servers.ghidra = ghidraMcp // {
    command = lib.getExe pkgs.pyghidra-mcp;
  };
}
