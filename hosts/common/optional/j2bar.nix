{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.j2bar.nixosModules.default ];

  # Settings live in ~/.config/j2bar/config.toml.
  programs.j2bar = {
    enable = true;
    hyprlandPlugin.enable = true;
    gameEngine.enable = true;
  };

  # The video wallpaper runs mpvpaper, which the module only installs for declared settings.
  environment.systemPackages = [ pkgs.mpvpaper ];

  # j2bar is launched by hand from a local build; the unit only supplies its environment.
  systemd.user.services.j2bar.wantedBy = lib.mkForce [ ];

  # Keep the existing TTY recovery path if the native locker cannot start.
  programs.hyprlock.enable = true;
}
