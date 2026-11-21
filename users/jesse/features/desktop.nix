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
      # On would bypass Auto's DOM fallback on Wayland, where WebGL context
      # creation can wedge terminal input before any recoverable context loss.
      terminalGpuAcceleration = "auto";
      pluginSystemEnabled = true;
      # The glass titlebar needs an alpha-capable window for Hyprland's blur.
      windowMaterial = "translucent";
      # A child branch fast-forwarded into local main reads as unchanged, not merged.
      workspaceCleanupPolicy = {
        merged.enabled = true;
        unchanged = {
          enabled = true;
          afterDays = 1;
        };
        inactive = {
          enabled = false;
          afterDays = 30;
          action = "archive";
        };
        automationRuns.enabled = false;
        orchestrationWorkers.enabled = false;
        keepWhen = "any-local-files";
      };
    }
    // lib.optionalAttrs (config.orca.agentResumeWrapper != null) {
      agentCmdOverrides = lib.genAttrs [
        "antigravity"
        "claude"
        "codex"
      ] sandboxAgentCommand;
    };
    telemetryOptedIn = false;
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
  # Orca only counts an agent's copy as its own when the agent folder links to a
  # real `.agents/skills` folder holding exactly its SKILL.md; a store link reads
  # as someone else's skill.
  sharedSkills = "${config.home.homeDirectory}/.agents/skills";
  skillsIn =
    directory:
    lib.genAttrs' orcaSkills (
      skill:
      lib.nameValuePair "${directory}/${skill}" {
        source = config.lib.file.mkOutOfStoreSymlink "${sharedSkills}/${skill}";
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
    description = "Command that Orca's automatic Claude, Codex and Antigravity resumes in local workspaces run through.";
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

    home.file = skillsIn ".claude/skills" // skillsIn ".gemini/config/skills";

    home.activation.orcaSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      for skill in ${lib.escapeShellArgs orcaSkills}; do
        target=${lib.escapeShellArg sharedSkills}/$skill
        if [ -L "$target" ] || { [ -e "$target" ] && [ ! -d "$target" ]; }; then
          run rm -f "$target"
        fi
        run mkdir -p "$target"
        run find "$target" -mindepth 1 -maxdepth 1 ! -name SKILL.md -exec rm -rf {} +
        if ! cmp -s ${orca-ade}/share/orca-ade/skills/$skill/SKILL.md "$target/SKILL.md"; then
          run rm -f "$target/SKILL.md"
          run install -m 644 ${orca-ade}/share/orca-ade/skills/$skill/SKILL.md "$target/SKILL.md"
        fi
      done
    '';

    home.sessionVariables = {
      DOWNLOAD = "/media/scratch/download";
    };

    xdg.mimeApps.enable = true;
  };
}
