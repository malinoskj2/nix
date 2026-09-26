{ config, pkgs, ... }:
let
  ssh = "${config.xdg.dataHome}/agent-sandbox/ssh";
in
{
  systemd.user.services."agent-sandbox@" = {
    Unit.Description = "Agent sandbox %i";
    Service = {
      Environment = "AGENT_SANDBOX_NAME=agent-sandbox-%i";
      WorkingDirectory = "%h/projects";
      ExecStart = "${pkgs.agent-sandbox}/bin/agent-sandbox sleep infinity";
      # The launcher exits 143 on SIGTERM.
      SuccessExitStatus = 143;
    };
  };

  # ~/.ssh/config stays hand-written; it pulls this in with `Include config.d/*`.
  home.file.".ssh/config.d/agent-sandbox".text = ''
    Host sandbox-*
      ProxyCommand ${pkgs.agent-sandbox}/bin/agent-sandbox-ssh %n
      User ${config.home.username}
      IdentityFile ${ssh}/client_ed25519
      IdentitiesOnly yes
      HostKeyAlias agent-sandbox
      UserKnownHostsFile ${ssh}/known_hosts
      StrictHostKeyChecking yes
  '';
}
