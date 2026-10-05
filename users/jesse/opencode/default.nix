_: {
  xdg.configFile = {
    "opencode/.gitignore".text = ''
      node_modules
      package.json
      package-lock.json
      bun.lock
      .gitignore
    '';

    "opencode/opencode.jsonc".text = ''
      {
        "$schema": "https://opencode.ai/config.json",
        "mcp": ${
          builtins.toJSON {
            unreal-mcp = {
              type = "remote";
              inherit (import ../../../pkgs/agent-sandbox/unreal-mcp.nix) url;
              enabled = true;
              oauth = false;
              timeout = 120000;
            };
          }
        }
      }
    '';

    "opencode/plugins/orca-opencode-status.js".source = ./plugins/orca-opencode-status.js;
    "opencode/plugins/sidebar-default.js".source = ./plugins/sidebar-default.js;
  };
}
