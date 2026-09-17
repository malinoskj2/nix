{ lib, pkgs, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  settingsOverlay = pkgs.writeText "claude-settings-overlay.json" (
    builtins.toJSON {
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
      enabledPlugins."caveman@caveman" = true;
      extraKnownMarketplaces.caveman.source = {
        source = "github";
        repo = "JuliusBrussee/caveman";
      };
      theme = "dark";
      skipDangerousModePermissionPrompt = true;
    }
  );

  mergeSettings = ''
    .[0] as $live
    | .[1] as $nix
    | ($live * $nix)
    | .permissions.allow = (($live.permissions.allow // []) as $kept | $kept + ($nix.permissions.allow - $kept))
  '';
in
{
  config = lib.mkMerge [
    {
      programs.claude-code = {
        enable = true;
        package = pkgs.unstable.claude-code;
        skills.gauntlet = ./skills/gauntlet;
      };

      home.sessionVariables.ANTHROPIC_MODEL = "claude-opus-5";
    }

    # The macbook profile is conservative: its CLAUDE.md and settings.json stay unmanaged.
    (lib.mkIf (!isDarwin) {
      programs.claude-code.context = ./CLAUDE.md;

      # Claude Code rewrites settings.json at runtime (/model, plugins, statusline, "always allow"
      # prompts), so merge the declared keys into the live file instead of symlinking a read-only
      # one through programs.claude-code.settings. Declared keys win; permissions.allow is unioned
      # so rules approved at runtime survive a switch.
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
