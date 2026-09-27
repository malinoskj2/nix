{ config, pkgs, ... }:
let
  themes = {
    catppuccin = pkgs.callPackage ./catppuccin.nix { inherit (config) palette; };
    light = pkgs.callPackage ./light.nix { inherit (config) palette; };
  };
  # Each theme's CSS is scoped to its own color scheme, so the app's appearance setting picks one.
  theme = pkgs.runCommand "claude-desktop-theme" { } ''
    mkdir $out
    for css in claude.css shell.css; do
      cat ${themes.light}/$css ${themes.catppuccin}/$css > $out/$css
    done
    cp ${themes.light}/{claude.js,title-bar-symbol-light} $out
    cp ${themes.catppuccin}/{title-bar-symbol,code-theme-dark} $out
  '';
in
{
  home.packages = [ (pkgs.claude-desktop.override { inherit theme; }) ];

  xdg.mimeApps.defaultApplications."x-scheme-handler/claude" = "com.anthropic.Claude.desktop";
}
