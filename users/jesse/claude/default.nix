{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  mergeSettings = ''
    .[0] as $live
    | .[1] as $nix
    | ($live * $nix)
    | .permissions.allow = (($live.permissions.allow // []) as $kept | $kept + ($nix.permissions.allow - $kept))
  '';

  settingsOverlay = pkgs.writeText "claude-settings-overlay.json" (
    builtins.toJSON {
      # The order reaches settings.json, so this list stays unsorted.
      permissions.allow = [
        "Bash(ls:*)"
        "Bash(find:*)"
        "Bash(cat:*)"
        "Bash(grep:*)"
        "Bash(rg:*)"
        "Bash(fd:*)"
        "Bash(git status:*)"
        "Bash(git log:*)"
        "Bash(git diff:*)"
        "Bash(git branch:*)"
        "Bash(git show:*)"
        "Bash(nix flake show:*)"
        "Bash(nix flake check:*)"
      ];

      extraKnownMarketplaces.caveman.source = {
        source = "github";
        repo = "JuliusBrussee/caveman";
      };

      enabledPlugins."caveman@caveman" = true;
      skipDangerousModePermissionPrompt = true;
      theme = "dark";
    }
  );
in
{
  config = lib.mkMerge [
    {
      home.sessionVariables.ANTHROPIC_MODEL = "claude-opus-5";

      programs.claude-code = {
        enable = true;
        package = pkgs.unstable.claude-code;
        skills.gauntlet = ./skills/gauntlet;
      };
    }

    # macOS leaves CLAUDE.md and settings.json unmanaged.
    (lib.mkIf (!isDarwin) {
      programs.claude-code.context = ./CLAUDE.md;

      # Claude Code rewrites settings.json at runtime (/model, plugins, statusline,
      # "always allow" prompts), so merge the declared keys into the live file instead of
      # symlinking a read-only one through programs.claude-code.settings. Declared keys
      # win; permissions.allow is unioned so rules approved at runtime survive a switch.
      home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        claudeSettings=$HOME/.claude/settings.json
        if [[ ! -f $claudeSettings ]]; then
          run install -D -m 644 ${settingsOverlay} "$claudeSettings"
        elif [[ ! -v DRY_RUN ]]; then
          claudeSettingsTmp=$(mktemp "$claudeSettings.XXXXXX")
          if ${lib.getExe pkgs.jq} -s ${lib.escapeShellArg mergeSettings} "$claudeSettings" ${settingsOverlay} > "$claudeSettingsTmp"; then
            mv "$claudeSettingsTmp" "$claudeSettings"
          else
            rm -f "$claudeSettingsTmp"
            exit 1
          fi
        fi
      '';
    })
  ];
}
