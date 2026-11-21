{
  config,
  inputs,
  pkgs,
  ...
}:
let
  inherit (config.home-manager.users.jesse.desktop) monitors;
in
{
  imports = [ inputs.tohru.nixosModules.tohru-greeter ];

  services.tohru-greeter = {
    enable = true;
    # The same build as the desktop shell, from Tohru's own pinned nixpkgs.
    package = inputs.tohru.packages.${pkgs.stdenv.hostPlatform.system}.default;
    style = "flooded-monolith";
    preferredOutput = monitors.main.output;
    defaultUser = "jesse";
    # Hyprland's own session, which runs start-hyprland; the desktop doesn't use UWSM.
    defaultSession = "hyprland";
    monitors = [
      monitors.side
      monitors.main
    ];
    wallpaper = ../../users/jesse/hyprland-desktop/wallpapers/mojave-night.jpg;
  };
}
