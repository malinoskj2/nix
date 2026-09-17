{ pkgs, ... }:
let
  schemas = pkgs.gsettings-desktop-schemas;
in
{
  # The graphical-desktop module enables speech-dispatcher in every session; nothing here uses it.
  services.speechd.enable = false;

  programs.hyprland.enable = true;

  environment.sessionVariables = {
    GSETTINGS_SCHEMA_DIR = "${schemas}/share/gsettings-schemas/${schemas.name}/glib-2.0/schemas";
    NIXOS_OZONE_WL = "1";
    NIXOS_XDG_OPEN_USE_PORTAL = "1";
    _JAVA_AWT_WM_NONREPARENTING = "1";
  };
}
