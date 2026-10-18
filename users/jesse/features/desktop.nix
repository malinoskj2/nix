{ lib, pkgs, ... }:
{
  imports = [
    ../claude-desktop
    ../dolphin
    ../firefox.nix
    ../mpv.nix
    ../pointer-cursor.nix
  ];

  home.packages = with pkgs; [
    blender
    chromium
    ffmpeg
    glib
    google-chrome
    imagemagick
    ktx-tools
    mediainfo
    (orca-ade.override {
      globalSettings = {
        theme = "dark";
        appFontFamily = "Geist";
        editorFontFamily = "FiraCode Nerd Font Mono";
        terminalFontFamily = "FiraCode Nerd Font Mono";
        terminalThemeDark = "Catppuccin Mocha";
        # Orca otherwise uses its launcher's SHELL, which a dev shell sets to bash.
        terminalDefaultShell = "/run/current-system/sw/bin/zsh";
      };
    })
    pwvucontrol
    vulkan-tools
    wl-clipboard
  ];

  home.file = lib.mergeAttrsList (
    lib.mapCartesianProduct
      (
        { agent, skill }:
        {
          ".${agent}/skills/${skill}".source = "${pkgs.orca-ade}/share/orca-ade/skills/${skill}";
        }
      )
      {
        agent = [
          "claude"
          "codex"
        ];
        skill = [
          "computer-use"
          "orca-cli"
          "orchestration"
        ];
      }
  );

  home.sessionVariables = {
    DOWNLOAD = "/media/scratch/download";
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications."x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 50400;
    maxCacheTtl = 50400;
  };
}
