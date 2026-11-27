{
  config,
  lib,
  pkgs,
  ...
}:
let
  broker = config.agentBroker;
  cfg = broker.push;
  configured = cfg.appId != null && cfg.installationId != null;
in
{
  options.agentBroker.push = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = broker.egress.enable;
      defaultText = lib.literalExpression "config.agentBroker.egress.enable";
      description = "The push gateway, which pushes sandbox branches to GitHub with short-lived GitHub App tokens.";
    };
    appId = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "The GitHub App's ID. Until it and the installation ID are set, the gateway refuses every push with setup instructions.";
    };
    installationId = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
    };
    repos = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+");
      default = [ ];
      description = "owner/name of the repositories sandboxes may push to. The App's installation must cover them too.";
    };
    protectedBranches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "main"
        "master"
      ];
      description = "Branches the gateway never pushes, besides each repository's default branch.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Declaring a secret the encrypted file lacks holds back every secret, so the key is only
    # declared once the owner has made the App.
    agentBroker.secrets = lib.mkIf configured { github-app-key = { }; };

    environment.etc."agent-broker/push.json".text = builtins.toJSON {
      inherit (cfg)
        appId
        installationId
        repos
        protectedBranches
        ;
      keyFile = if configured then broker.secrets.github-app-key.path else null;
    };

    agentBroker.services.push = {
      description = "Agent sandbox push gateway";
      path = [ pkgs.agent-push ];
      script = "exec agent-push --config /etc/agent-broker/push.json";
      serviceConfig = {
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
