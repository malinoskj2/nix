{
  config,
  lib,
  pkgs,
  osConfig ? { },
  ...
}:
let
  # Resolve on the execution host, including Darwin hosts reached over SSH.
  sandboxAgentCommand =
    agent:
    "/bin/sh -c ${
      lib.escapeShellArg (
        lib.replaceStrings [ "\n" ] [ " " ] ''
          case "$(uname -s)" in
            Darwin)
              remaining=$PATH;
              while :; do
                directory=''${remaining%%:*};
                for candidate in "''${directory:-.}"/sandbox-*; do
                  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
                    exec "$candidate" "$@";
                  fi;
                done;
                case $remaining in
                  *:*) remaining=''${remaining#*:} ;;
                  *) break ;;
                esac;
              done;
              echo 'Orca: no executable sandbox-* command found in PATH' >&2;
              exit 127 ;;
            Linux) exec agent-sandbox-exec "$@" ;;
            *) echo 'Orca: unsupported sandbox host OS' >&2; exit 1 ;;
          esac
        ''
      )
    } orca-sandbox ${agent}";
  orca-ade = pkgs.orca-ade.override {
    globalSettings = {
      theme = "dark";
      appFontFamily = "Geist";
      editorFontFamily = "FiraCode Nerd Font Mono";
      terminalFontFamily = "FiraCode Nerd Font Mono";
      terminalThemeDark = "Catppuccin Mocha";
      # Orca otherwise uses its launcher's SHELL, which a dev shell sets to bash.
      terminalDefaultShell = "/run/current-system/sw/bin/zsh";
      pluginSystemEnabled = true;
      # The glass titlebar needs an alpha-capable window for Hyprland's blur.
      windowMaterial = "translucent";
    }
    // lib.optionalAttrs (config.orca.agentResumeWrapper != null) {
      agentCmdOverrides = lib.genAttrs [
        "antigravity"
        "claude"
        "codex"
        "muse"
      ] sandboxAgentCommand;
    };
    approvedPlugins = [
      "chron0.discord-presence"
      "etherll.usage-insights"
    ];
    # Generic keeps workspace, branch and machine names out of the activity.
    discordPresenceSettings.detailLevel = "generic";
    inherit (config.orca) agentResumeWrapper codexAccountHomes usageInsightsSettings;
  };
  orcaSkills = [
    "orca-computer-use"
    "orca-cli"
    "orchestration"
  ];
  skillsIn =
    directory:
    lib.genAttrs' orcaSkills (
      skill:
      lib.nameValuePair "${directory}/${skill}" {
        source = "${orca-ade}/share/orca-ade/skills/${skill}";
      }
    );
in
{
  imports = [
    ../arrpc
    ../firefox.nix
    ../mpv.nix
    ../pointer-cursor.nix
  ];

  options.orca.agentResumeWrapper = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Command that Orca's automatic Claude, Codex, Muse and Antigravity resumes in local workspaces run through.";
  };

  options.orca.usageInsightsSettings = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    description = "Default lines for the bundled Usage Insights plugin's multiline settings, by setting key.";
  };

  options.orca.codexAccountHomes = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional local Codex account homes trusted for history discovery and resume, including Continue in chat.";
  };

  config = {
    home.packages = with pkgs; [
      blender
      chromium
      ffmpeg
      glib
      google-chrome
      imagemagick
      ktx-tools
      mediainfo
      orca-ade
      pwvucontrol
      vulkan-tools
      wl-clipboard
    ];

    systemd.user.services.resource-job-notifications =
      lib.mkIf (pkgs.stdenv.isLinux && (osConfig.services.resourceScheduler.queue.enable or false))
        {
          Unit = {
            Description = "Deliver resource job completions to their submitting Orca sessions";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
          };
          Service = {
            ExecStart = "${pkgs.resource-scheduler}/bin/resource-notify --orca ${orca-ade}/bin/orca-ide";
            Restart = "on-failure";
            RestartSec = 10;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

    home.file =
      skillsIn ".claude/skills" // skillsIn ".codex/skills" // skillsIn ".gemini/config/skills";

    home.sessionVariables = {
      DOWNLOAD = "/media/scratch/download";
    };

    xdg.mimeApps.enable = true;
  };
}
