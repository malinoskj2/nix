{
  config,
  lib,
  pkgs,
  ...
}:
let
  ssh = "${config.xdg.dataHome}/agent-sandbox/ssh";
in
{
  # Orca resumes agents when it reopens; this resumes the ones `sandbox` started in a sandbox again.
  orca.agentResumeWrapper = "agent-sandbox-resume";
  # Continue in chat admits hook transcript paths only inside recognized account homes.
  # The launcher mounts this selected account at the same host path when Chat resumes it.
  orca.codexAccountHomes = [ "${config.xdg.dataHome}/agent-sandbox/home/.codex" ];
  # Sandboxed Claude shares ~/.claude/projects, but sandboxed Codex keeps its own home.
  orca.usageInsightsSettings.extraCodexFolders = [
    "${config.xdg.dataHome}/agent-sandbox/home/.codex"
  ];

  # Host /proc can attribute NVIDIA's host PIDs across every sandbox namespace.
  # The existing shared scheduler mount exposes only this read-only telemetry API.
  systemd.user.sockets.gpu-scheduler-telemetry = {
    Unit.Description = "GPU reservation memory telemetry";
    Socket = {
      ListenStream = "%t/gpu-scheduler/telemetry.sock";
      SocketMode = "0600";
      DirectoryMode = "0700";
      RemoveOnStop = true;
    };
    Install.WantedBy = [ "sockets.target" ];
  };
  systemd.user.services.gpu-scheduler-telemetry = {
    Unit.Description = "Attribute GPU memory to reservations across sandboxes";
    Service = {
      ExecStart = lib.getExe' pkgs.gpu-scheduler "gpu-scheduler-telemetry";
      NoNewPrivileges = true;
      Restart = "on-failure";
    };
  };

  systemd.user.services."agent-sandbox@" = {
    Unit = {
      Description = "Agent sandbox %i";
      # Running sessions keep their launcher; updates apply on the next start.
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Environment = "AGENT_SANDBOX_NAME=agent-sandbox-%i";
      WorkingDirectory = "%h/projects";
      ExecStart = "${lib.getExe pkgs.agent-sandbox} sleep infinity";
      # The launcher exits 143 on SIGTERM.
      SuccessExitStatus = 143;
    };
  };

  # Sandbox launchers start it; it then stays up for later sandboxes.
  systemd.user.services.agent-sandbox-codex-server = {
    Unit.Description = "Codex app-server shared by the agent sandboxes";
    Service = {
      ExecStart = lib.getExe' pkgs.agent-sandbox "agent-sandbox-codex-server";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Wipes the shared sandbox home except logins, Steam and the kept caches, at
  # most weekly and only while no sandbox runs.
  systemd.user.services.agent-sandbox-clean = {
    Unit.Description = "Clean the agent sandbox home";
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' pkgs.agent-sandbox "agent-sandbox-clean"} --if-older-than 7";
      SuccessExitStatus = 75;
    };
  };

  systemd.user.timers.agent-sandbox-clean = {
    Unit.Description = "Clean the agent sandbox home when it is idle";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # ~/.ssh/config stays hand-written; it pulls this in with `Include config.d/*`.
  home.file.".ssh/config.d/agent-sandbox".text = ''
    Host sandbox-*
      ProxyCommand ${lib.getExe' pkgs.agent-sandbox "agent-sandbox-ssh"} %n
      User ${config.home.username}
      IdentityFile ${ssh}/client_ed25519
      IdentitiesOnly yes
      HostKeyAlias agent-sandbox
      UserKnownHostsFile ${ssh}/known_hosts
      StrictHostKeyChecking yes
  '';
}
