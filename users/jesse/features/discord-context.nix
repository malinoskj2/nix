{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.discord-context;
  policy = pkgs.writeText "discord-context-policy.json" (
    builtins.toJSON {
      inherit (cfg) excludedGuilds excludedChannels;
    }
  );
  url = "http://127.0.0.1:7781/mcp";
  ids =
    description:
    lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9]{1,20}");
      default = [ ];
      inherit description;
    };
in
{
  options.services.discord-context = {
    excludedGuilds = ids "Server IDs excluded from reading and searching. All other servers are allowed.";
    excludedChannels = ids "Excluded channel/category IDs, including all descendant threads and channels.";
  };

  config = {
    home.packages = [ pkgs.discord-context ];
    systemd.user.services.discord-context = {
      Unit = {
        Description = "Read-only Discord context MCP";
        ConditionPathExists = "%h/.config/discord-context/token";
        After = [ "network-online.target" ];
      };
      Service = {
        ExecStart = lib.getExe pkgs.discord-context;
        LoadCredential = "discord-token:%h/.config/discord-context/token";
        Environment = [
          "DISCORD_TOKEN_FILE=%d/discord-token"
          "DISCORD_POLICY_FILE=${policy}"
        ];
        Restart = "on-failure";
        RestartSec = 10;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        # Keep homes hidden without blocking traversal to systemd's /run/user credentials.
        ProtectHome = "tmpfs";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };

    programs.claude-code.mcpServers.discord-context = {
      type = "http";
      inherit url;
    };
    programs.codex.settings.mcp_servers.discord-context = {
      inherit url;
      startup_timeout_sec = 10;
      tool_timeout_sec = 180;
    };
  };
}
