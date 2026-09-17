#!/usr/bin/env bash
# Pause each monitor's Noctalia video wallpaper while its visible workspace has windows.
#
# Every wallpaper stays paused while the Noctalia lock screen is up, since the video is hidden
# behind it. Updates are event-driven: Hyprland events cover windows, workspaces and new mpvpaper
# surfaces, and logind's LockedHint covers locking and unlocking.

readonly mpvpaper_dir="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"

find_hyprland_socket() {
  local candidate
  local -a candidates

  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    candidate="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
    if [[ -S "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi

  shopt -s nullglob
  candidates=("$XDG_RUNTIME_DIR"/hypr/*/.socket2.sock)
  shopt -u nullglob
  if ((${#candidates[@]} == 1)); then
    printf '%s\n' "${candidates[0]}"
    return
  fi

  return 1
}

# Prints "<monitor> <true|false>" per monitor, where true means it has windows and should pause.
print_monitor_states() {
  jq -rn \
    --argjson monitors "$(hyprctl -j monitors)" \
    --argjson workspaces "$(hyprctl -j workspaces)" '
    ($workspaces | map({key: (.id | tostring), value: .windows}) | from_entries) as $count
    | $monitors[]
    | (($count[.activeWorkspace.id | tostring] // 0)
      + ($count[.specialWorkspace.id | tostring] // 0)) as $windows
    | "\(.name) \($windows > 0)"'
}

# Fails if any monitor's mpv couldn't be reached.
apply_pause_states() {
  local locked

  # An unreachable Noctalia counts as locked so the video never plays unseen.
  locked="$(noctalia msg status 2>/dev/null | jq -r '.locked' 2>/dev/null || true)"
  [[ "$locked" == false ]] || locked=true

  print_monitor_states | {
    failed=0
    while read -r monitor pause; do
      [[ "$locked" == true ]] && pause=true
      printf '{"command":["set_property","pause",%s]}\n' "$pause" |
        socat - "UNIX-CONNECT:$mpvpaper_dir/ipc-$monitor.sock" >/dev/null 2>&1 || failed=1
    done
    ((failed == 0))
  }
}

# A (re)started mpvpaper maps its surface slightly before its mpv IPC socket is up, hence the
# retries. Instances start paused (mpv_options), so nothing plays in the meantime.
apply_to_new_instance() {
  for _ in {1..10}; do
    apply_pause_states && return
    sleep 0.5
  done
}

# The user unit can start before Hyprland's environment reaches systemd, so the script waits for
# the compositor socket and derives the signature from it when needed. On failure, systemd
# restarts the service.
socket=
for _ in {1..30}; do
  socket="$(find_hyprland_socket)" && break
  sleep 1
done
[[ -n "$socket" ]] || exit 1

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  instance_dir="${socket%/.socket2.sock}"
  export HYPRLAND_INSTANCE_SIGNATURE="${instance_dir##*/}"
fi

session_id="${XDG_SESSION_ID:-$(loginctl show-user "$USER" --property=Display --value)}"
[[ -n "$session_id" ]] || exit 1
session_path="$(
  busctl --system --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager GetSession s "$session_id" | jq -r '.data[0]'
)"
[[ -n "$session_path" ]] || exit 1

apply_to_new_instance

# Exit with the compositor so the next Hyprland start can start a fresh unit; a lingering gdbus
# would otherwise keep this instance active on a dead socket.
{
  socat -u "UNIX-CONNECT:$socket" - &
  socat_pid=$!
  gdbus monitor --system --dest org.freedesktop.login1 --object-path "$session_path" &
  gdbus_pid=$!
  wait "$socat_pid" || true
  kill "$gdbus_pid" 2>/dev/null || true
} | while read -r line; do
  case "$line" in
    openlayer\>\>mpvpaper*) apply_to_new_instance ;;
    # These events can change the visible workspaces, their window counts or the lock state. A
    # failed update is left for the next event to retry rather than ending the service.
    workspace* | focusedmon* | activespecial* | monitor* | openwindow* | closewindow* | \
      movewindow* | changefloatingmode* | *LockedHint*)
      apply_pause_states || true
      ;;
  esac
done
