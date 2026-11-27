{
  config,
  lib,
  pkgs,
  ...
}:
let
  playwrightArgs = [
    "--headless"
    "--output-dir"
    "${config.xdg.cacheHome}/playwright-mcp"
  ];
in
{
  imports = [
    ./unreal-mcp.nix
    ../antigravity
  ];

  home.packages = with pkgs; [
    betterleaks-push-gate.gh
    council
    gnumake
    nil
    nixfmt
    nodejs
    pkg-config
    playwright-test
    python3
    ts-lints
  ];

  home.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };

  programs.claude-code.mcpServers.playwright = {
    command = lib.getExe pkgs.playwright-mcp;
    args = playwrightArgs;
  };
  programs.opencode.settings.mcp.servers.playwright = {
    type = "local";
    command = [ (lib.getExe pkgs.playwright-mcp) ] ++ playwrightArgs;
  };
}
