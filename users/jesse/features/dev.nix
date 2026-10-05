{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./unreal-mcp.nix ];

  home.packages = with pkgs; [
    gnumake
    muse
    nil
    nixfmt
    nodejs
    pkg-config
    playwright-test
    python3
    zcode

    unstable.codex
    unstable.opencode
  ];

  home.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };

  programs.claude-code.mcpServers.playwright = {
    command = lib.getExe pkgs.playwright-mcp;
    args = [
      "--headless"
      "--output-dir"
      "${config.xdg.cacheHome}/playwright-mcp"
    ];
  };
}
