{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  mergeSettings = ''
    .[0] as $live
    | .[1] as $nix
    | ($live * $nix)
    | reduce ("allow", "deny") as $list (.;
        .permissions[$list] = (($live.permissions[$list] // []) as $kept | $kept + ($nix.permissions[$list] - $kept)))
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

      # Deny rules hold even when permission prompts are bypassed.
      permissions.deny = [
        "Read(~/.ssh/**)"
        "Read(~/.gnupg/**)"
        "Read(**/.env)"
        "Read(**/secrets/**)"
        "Bash(nh os switch:*)"
        "Bash(nixos-rebuild switch:*)"
        "Bash(darwin-rebuild switch:*)"
        "Bash(git push --force:*)"
        "Bash(git push -f:*)"
        "Bash(git reset --hard:*)"
        "Bash(rm -rf /:*)"
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
