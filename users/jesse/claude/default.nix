{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  settingsFile = "${cfg.configDir}/settings.json";
  settingsSource = config.home.file.${settingsFile}.source;
  merge-settings = pkgs.writeShellApplication {
    name = "claude-merge-settings";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./merge-settings.sh;
  };
  archive-completed-task = pkgs.writeShellApplication {
    name = "archive-completed-task";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./archive-completed-task.sh;
  };
in
{
  home.file.".claude/keybindings.json".source = ./keybindings.json;
  home.file.${settingsFile}.enable = false;

  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run mkdir -p ${lib.escapeShellArg cfg.configDir}
    run ${lib.getExe merge-settings} ${settingsSource} ${lib.escapeShellArg settingsFile}
    # The agent sandbox seeds its settings.json from this one only once.
    sandboxSettings="${config.xdg.dataHome}/agent-sandbox/home/.claude/settings.json"
    if [ -s "$sandboxSettings" ]; then
      run ${lib.getExe merge-settings} ${settingsSource} "$sandboxSettings"
    fi
  '';

  xdg.mimeApps.defaultApplications."x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";

  programs.claude-code = {
    enable = true;
    package = pkgs.unstable.claude-code;
    context = ./CLAUDE.md;
    agents = {
      laravel-builder = ./agents/laravel-builder.md;
      laravel-orchestrator = ./agents/laravel-orchestrator.md;
      laravel-reviewer = ./agents/laravel-reviewer.md;
      rust-builder = ./agents/rust-builder.md;
      rust-reviewer = ./agents/rust-reviewer.md;
    };
    skills = {
      audio-transcribe = ./skills/audio-transcribe;
      codex-image = ./codex-image;
      game-latency = ./skills/game-latency;
      gauntlet = ./skills/gauntlet;
      laravel-build-jesse = ./skills/laravel-build-jesse;
      laravel-orchestrator = ./skills/laravel-orchestrator;
      laravel-review-jesse = ./skills/laravel-review-jesse;
      media-gallery = ./skills/media-gallery;
      recommit = ./skills/recommit;
      rust-build-jesse = ./skills/rust-build-jesse;
      rust-design-jesse = ./skills/rust-design-jesse;
      rust-review-jesse = ./skills/rust-review-jesse;
      sandbox-wayland-display = ./skills/sandbox-wayland-display;
      tiktok-search = ./skills/tiktok-search;
      true-random = ./skills/true-random;
      video-download = ./skills/video-download;
      work-queue = ./skills/work-queue;
      youtube-search = ./skills/youtube-search;
    };
    rules = {
      gpu = ./rules/gpu.md;
      resources = ./rules/resources.md;
      local-models = ./rules/local-models.md;
      media = ./rules/media.md;
      rust = ./rules/rust.md;
      sandbox-display = ./rules/sandbox-display.md;
      sandbox-previews = ./rules/sandbox-previews.md;
      worktrees = ./rules/worktrees.md;
    };

    settings = {
      model = "claude-opus-5-5[1m]";
      effortLevel = "high";
      modelSettings.claude-opus-5-5.effortLevel = "high";
      theme = "dark";
      skipDangerousModePermissionPrompt = true;
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;
      autoContinueAtUsageLimit = true;
      worktree.baseRef = "head";
      attribution = {
        commit = "";
        pr = "";
      };
      env = {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        CLAUDE_CODE_ENABLE_TODO_TOOLS = "1";
      };
      hooks.PostToolUse = [
        {
          matcher = "TaskUpdate";
          hooks = [
            {
              type = "command";
              command = lib.getExe archive-completed-task;
            }
          ];
        }
      ];
      permissions = {
        allow = [ "Bash" ];
        ask = [ "Bash(git push:*)" ];
        # Deny rules hold even when permission prompts are bypassed.
        deny = [
          "Read(~/.ssh/**)"
          "Read(~/.gnupg/**)"
          "Read(**/.env)"
          "Read(**/secrets/**)"
          "Bash(git push --force:*)"
          "Bash(git push -f:*)"
          "Bash(git reset --hard:*)"
          "Bash(rm -rf /:*)"
        ];
      };
    };
  };
}
