{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.packages = with pkgs; [
    gnumake
    nil
    nixfmt
    nodejs
    pkg-config
    playwright-test
    python3

    unstable.codex
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
