{ lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  settingsOverlay = pkgs.writeText "claude-settings-overlay.json" (
    builtins.toJSON {
      permissions = {
        allow = [
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
      };
      enabledPlugins = {
        "caveman@caveman" = true;
      };
      extraKnownMarketplaces = {
        caveman = {
          source = {
            source = "github";
            repo = "JuliusBrussee/caveman";
          };
        };
      };
      theme = "dark";
      skipDangerousModePermissionPrompt = true;
    }
  );
in
{
  programs.claude-code = {
    enable = true;
    package = pkgs.unstable.claude-code;
    skills.gauntlet = ./skills/gauntlet;
  }
  // lib.optionalAttrs (!isDarwin) {
    context = ./CLAUDE.md;
  };

  # settings.json is written to at runtime by Claude Code itself (/model,
  # /effort, statusline, plugins), so it can't be managed via
  # programs.claude-code.settings (that makes the file read-only). Instead,
  # overlay the nix-declared static keys onto the live file at activation:
  # live file first so its runtime-managed keys survive, overlay last so it
  # wins on the 5 static keys.
  home.activation.claudeSettings = lib.mkIf (!isDarwin) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      claudeSettings="$HOME/.claude/settings.json"
      if [[ -f "$claudeSettings" ]]; then
        claudeSettingsTmp="$(${lib.getExe' pkgs.coreutils "mktemp"} "''${TMPDIR:-/tmp}/claude-settings.XXXXXX")"
        trap 'rm -f "$claudeSettingsTmp"' EXIT
        run ${lib.getExe' pkgs.jq "jq"} -s '.[0] * .[1]' "$claudeSettings" "${settingsOverlay}" > "$claudeSettingsTmp"
        run mv "$claudeSettingsTmp" "$claudeSettings"
        trap - EXIT
      else
        run mkdir -p "$(dirname "$claudeSettings")"
        run cp "${settingsOverlay}" "$claudeSettings"
      fi
    ''
  );
}
