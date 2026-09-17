# katana: ThinkPad laptop running Hyprland.
{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global.nix
    ../common/users/jesse
    ../common/users/jesse/workstation.nix
    ../common/optional/fonts.nix
    ../common/optional/hyprland.nix
    ../common/optional/nh.nix
    ../common/optional/pipewire.nix
    ../common/optional/systemd-boot.nix
    ../common/optional/workstation.nix
  ];

  networking = {
    hostName = "katana";

    # No declarative interfaces or wireless networks on purpose. The NixOS
    # default (networking.useDHCP) already leases on every interface, and wifi
    # is joined imperatively with `wifi-connect`.
  };

  hardware.graphics.extraPackages = with pkgs; [
    libva-vdpau-driver
    libvdpau-va-gl
  ];

  environment.sessionVariables = {
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_DESKTOP = "Hyprland";
    GTK_USE_PORTAL = "1";
  };

  fonts.packages = [ pkgs.nerd-fonts.droid-sans-mono ];

  environment.systemPackages = [ pkgs.read-edid ];

  system.stateVersion = "24.11";
}
