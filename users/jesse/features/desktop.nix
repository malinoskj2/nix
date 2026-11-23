{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Both Orca's native parser and terminal shells expand this on the execution host.
  sandboxAgentCommand = agent: "~/.orca/nix/bin/orca-sandbox-launch orca-sandbox ${agent}";
  orca-ade = pkgs.orca-ade.override {
    hostCodexBotCommands = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      "3001d2e5-f2ec-4efc-965d-7be4b9e99e02" = lib.getExe config.programs.codex.package;
    };
    desktopAssistantCommand =
      if config.programs ? tohru && config.programs.tohru.enable then
        "${config.programs.tohru.package}/bin/tohru"
      else
        "tohru";
    globalSettings = {
      theme = "dark";
      pluginAppThemeDark = "plugin:local.catppuccin-mocha/mocha";
      editorThemeDark = "plugin:local.catppuccin-mocha/mocha";
      keepComputerAwakeWhileAgentsRun = true;
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
  orcaSetup = pkgs.writeText "orca-declarative-setup.json" (
    builtins.toJSON {
      cli = "${orca-ade}/bin/orca-ide";
      plugins = lib.genAttrs [
        "chron0.discord-presence"
        "etherll.usage-insights"
        "local.catppuccin-mocha"
      ] (key: "${orca-ade}/share/orca-ade/plugins/${key}");
      baseRefs = config.orca.localBaseRefs;
    }
  );
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
    description = "Default lines for the Nix-installed Usage Insights plugin's multiline settings, by setting key.";
  };

  options.orca.localBaseRefs = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {
      "${config.home.homeDirectory}/nix" = "main";
    };
    description = "Initial native worktree base refs, scoped to existing local Orca repositories by exact path; existing persisted choices are preserved.";
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

    home.file =
      skillsIn ".claude/skills"
      // skillsIn ".gemini/config/skills"
      // {
        ".orca/nix/bin/orca-sandbox-launch" = {
          source = ../../../pkgs/orca-ade/sandbox-launch.sh;
          executable = true;
        };
      };

    # Runtime CLI calls belong after login, not in builds or HM activation. Retry when Orca
    # becomes available; source paths make installs idempotent and pin them to this generation.
    systemd.user.services.orca-declarative-setup = {
      Unit.Description = "Install declared Orca plugins and seed scoped repository bases";
      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${../orca/reconcile.py} ${orcaSetup} %S/orca-nix/initialized-repos.json";
        Environment = "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.git
          ]
        }";
        TimeoutStartSec = 600;
      };
    };
    systemd.user.timers.orca-declarative-setup = {
      Unit.Description = "Retry declarative Orca setup when its runtime is available";
      Timer = {
        OnStartupSec = "30s";
        OnUnitInactiveSec = "1min";
      };
      Install.WantedBy = [ "timers.target" ];
    };

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
