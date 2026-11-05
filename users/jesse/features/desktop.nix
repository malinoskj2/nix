{
  config,
  lib,
  pkgs,
  ...
}:
let
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
    ../claude-desktop
    ../dolphin
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
