{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  shared = import ../agent-shared.nix {
    inherit lib;
    queue = osConfig.services.resourceScheduler.queue.enable or false;
  };
  home = config.home.homeDirectory;
  json = pkgs.formats.json { };
  mcpConfig = json.generate "antigravity-mcp-config.json" {
    mcpServers = config.programs.antigravity.mcpServers;
  };
  settings = json.generate "antigravity-settings.json" {
    toolPermission = "always-proceed";
    # Deny rules hold in every mode, including --dangerously-skip-permissions.
    permissions = {
      ask = [ "command(git push)" ];
      deny = [
        "read_file(${home}/.ssh)"
        "read_file(${home}/.gnupg)"
        "command(git push --force)"
        "command(git push -f)"
        "command(git reset --hard)"
        "command(rm -rf /)"
      ];
    };
  };
  # agy saves trust, its model and /config choices to settings.json and rewrites it at startup, and
  # `agy mcp` edits mcp_config.json, so Nix's keys are merged into writable files instead of links.
  mergeJson = pkgs.writeShellApplication {
    name = "antigravity-merge-json";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      base=$1
      target=$2
      existing='{}'
      if [[ -s $target ]] && jq -e 'type == "object"' "$target" >/dev/null 2>&1; then
        existing=$(<"$target")
      fi
      mkdir -p "$(dirname "$target")"
      tmp=$(mktemp "$target.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      jq --slurpfile base "$base" '. * $base[0]' <<<"$existing" >"$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$target"
    '';
  };
in
{
  options.programs.antigravity.mcpServers = lib.mkOption {
    inherit (json) type;
    default = { };
    description = "MCP servers merged into Antigravity's global mcp_config.json.";
  };

  config.home.packages = [ pkgs.antigravity-cli ];

  config.home.file = {
    ".gemini/GEMINI.md".text = shared.context;
    ".gemini/config/skills" = {
      source = shared.skills;
      recursive = true;
    };
  };

  config.home.activation.antigravitySettings = lib.hm.dag.entryAfter [ "linkGeneration" ] (
    ''
      run ${lib.getExe mergeJson} ${settings} "$HOME/.gemini/antigravity-cli/settings.json"
      # The agent sandbox seeds its settings.json from this one only once.
      sandboxSettings="${config.xdg.dataHome}/agent-sandbox/home/.gemini/antigravity-cli/settings.json"
      if [ -s "$sandboxSettings" ]; then
        run ${lib.getExe mergeJson} ${settings} "$sandboxSettings"
      fi
    ''
    + lib.optionalString (config.programs.antigravity.mcpServers != { }) ''
      run ${lib.getExe mergeJson} ${mcpConfig} "$HOME/.gemini/config/mcp_config.json"
    ''
  );
}
