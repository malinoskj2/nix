{
  config,
  lib,
  pkgs,
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
        "claude"
        "codex"
        "muse"
      ] sandboxAgentCommand;
    };
    approvedPlugins = [ "chron0.discord-presence" ];
    # Generic keeps workspace, branch and machine names out of the activity.
    discordPresenceSettings.detailLevel = "generic";
    inherit (config.orca) agentResumeWrapper;
  };
  orcaSkills = [
    "computer-use"
    "orca-cli"
    "orchestration"
  ];
  skillsFor =
    agent:
    lib.genAttrs' orcaSkills (
      skill:
      lib.nameValuePair ".${agent}/skills/${skill}" {
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
    description = "Command that Orca's automatic Claude, Codex and Muse resumes in local workspaces run through.";
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

    home.file = skillsFor "claude" // skillsFor "codex";

    home.sessionVariables = {
      DOWNLOAD = "/media/scratch/download";
    };

    xdg.mimeApps.enable = true;
  };
}
