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
  };

  # The video wallpaper runs mpvpaper, which the module only installs for declared settings.
  environment.systemPackages = [ pkgs.mpvpaper ];

  # j2bar is launched by hand from a local build; the unit only supplies its environment.
  systemd.user.services.j2bar.wantedBy = lib.mkForce [ ];

  # If j2bar's locker can't start, hyprlock run from a TTY takes over the lock, which Hyprland
  # allows with allow_session_lock_restore.
  programs.hyprlock.enable = true;
}
