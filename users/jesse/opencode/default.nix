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
        "$schema": "https://opencode.ai/config.json"
      }
    '';

    "opencode/plugins/orca-opencode-status.js".source = ./plugins/orca-opencode-status.js;
    "opencode/plugins/sidebar-default.js".source = ./plugins/sidebar-default.js;
  };
}
