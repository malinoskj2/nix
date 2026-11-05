{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config) palette;
  theme = pkgs.runCommand "claude-desktop-theme" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./theme}/main.py \
      ${lib.escapeShellArg (builtins.toJSON palette.mocha)} \
      ${lib.escapeShellArg (palette.withAlpha palette.mocha.crust palette.glass.chrome)} \
      $out
    cp ${./claude.js} $out/claude.js
  '';
in
lib.mkIf (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.claude-desktop) {
  home.packages = [ (pkgs.claude-desktop.override { inherit theme; }) ];

  xdg.mimeApps.defaultApplications."x-scheme-handler/claude" = "com.anthropic.Claude.desktop";
}
