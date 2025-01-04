# Wayland
{ services, programs, pkgs, lib, config, ... }:

{
  boot.kernelParams = [ "nvidia-drm.modeset=1" "nvidia-drm.fbdev=1" ];

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
    nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = false;
      forceFullCompositionPipeline = true;
      powerManagement.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
        version = "555.58";
        sha256_64bit = "sha256-bXvcXkg2kQZuCNKRZM5QoTaTjF4l2TtrsKUvyicj5ew=";
        sha256_aarch64 = "sha256-7XswQwW1iFP4ji5mbRQ6PVEhD4SGWpjUJe1o8zoXYRE=";
        openSha256 = "sha256-hEAmFISMuXm8tbsrB+WiUcEFuSGRNZ37aKWvf0WJ2/c=";
        settingsSha256 =
          "sha256-vWnrXlBCb3K5uVkDFmJDVq51wrCoqgPF03lSjZOuU8M="; # "sha256-m2rNASJp0i0Ez2OuqL+JpgEF0Yd8sYVCyrOoo/ln2a4=";
        persistencedSha256 =
          lib.fakeHash; # "sha256-XaPN8jVTjdag9frLPgBtqvO/goB5zxeGzaTU0CdL6C4=";
      };
    };
  };

  environment.sessionVariables = {
    POLKIT_AUTH_AGENT =
      "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    GSETTINGS_SCHEMA_DIR =
      "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
    LIBVA_DRIVER_NAME = "nvidia";
    XDG_SESSION_TYPE = "wayland";
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
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

