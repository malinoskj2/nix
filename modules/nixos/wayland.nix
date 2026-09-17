# Shared Wayland environment for the home and katana desktop hosts.
{ pkgs, ... }:

{
  environment.sessionVariables = {
    GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
    NIXOS_OZONE_WL = "1";
    _JAVA_AWT_WM_NONREPARENTING = "1";
    NIXOS_XDG_OPEN_USE_PORTAL = "1";
  };
}
