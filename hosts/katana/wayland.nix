# Wayland
{ services, programs, pkgs, lib, config, ... }:

{
  programs.hyprland = {
    enable = true;
    xwayland = { enable = true; };
  };

  xdg = {
    autostart.enable = true;
    portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal pkgs.xdg-desktop-portal-gtk ];
    };
  };

  hardware = {
    graphics = {
      enable = true;
      extraPackages = with pkgs; [ vaapiVdpau libvdpau-va-gl ];
      extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
    };
  };

  environment.sessionVariables = {
    POLKIT_AUTH_AGENT =
      "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    GSETTINGS_SCHEMA_DIR =
      "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
    XDG_SESSION_TYPE = "wayland";
    WLR_NO_HARDWARE_CURSORS = "1";
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    SDL_VIDEODRIVER = "wayland";
    _JAVA_AWT_WM_NONREPARENTING = "1";
    CLUTTER_BACKEND = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
    GTK_USE_PORTAL = "1";
    NIXOS_XDG_OPEN_USE_PORTAL = "1";
  };
}

