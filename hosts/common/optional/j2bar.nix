{
  # j2bar's lock screen checks the password against this service.
  security.pam.services.j2bar = { };

  # The way back in when j2bar's locker can't be started: `hyprlock` from a TTY takes the lock
  # over, which Hyprland allows with `allow_session_lock_restore`.
  programs.hyprlock.enable = true;
}
