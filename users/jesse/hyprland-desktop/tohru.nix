{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  # Tohru is only built and tested for x86_64-linux; other hosts run Hyprland without a shell.
  package = inputs.tohru.packages.${system}.default or null;
in
{
  imports = [ inputs.tohru.homeManagerModules.default ];

  programs.tohru = {
    enable = package != null;
    package = lib.mkIf (package != null) package;
    systemd.enable = true;
    polkit.enable = true;
    lock.style = "flooded-monolith";
    settings.bar.preferred_output = config.desktop.monitors.main.output;
  };

  home.packages = [ pkgs.grimblast ];
  home.sessionVariables.XDG_SCREENSHOTS_DIR = "${config.home.homeDirectory}/Pictures/Screenshots";
  systemd.user.tmpfiles.rules = [ "d %h/Pictures/Screenshots - - - -" ];
}
