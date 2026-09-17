# katana: ThinkPad X230 laptop, Hyprland workstation.
{ pkgs, ... }:
{
  imports = [
    ../common/global.nix
    ../common/optional/fonts.nix
    ../common/optional/hyprland.nix
    ../common/optional/nh.nix
    ../common/optional/pipewire.nix
    ../common/optional/systemd-boot.nix
    ../common/optional/workstation.nix
    ../common/users/jesse
    ../common/users/jesse/interactive.nix

    ./hardware-configuration.nix
  ];

  networking.hostName = "katana";

  hardware.graphics.extraPackages = with pkgs; [
    libva-vdpau-driver
    libvdpau-va-gl
  ];

  fonts.packages = [ pkgs.nerd-fonts.droid-sans-mono ];

  environment.sessionVariables = {
    CLUTTER_BACKEND = "wayland";
    GTK_USE_PORTAL = "1";
    SDL_VIDEODRIVER = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
  };

  environment.systemPackages = [ pkgs.read-edid ];

  system.stateVersion = "24.11";
}
