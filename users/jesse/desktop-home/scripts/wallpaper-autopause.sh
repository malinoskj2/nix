#!/usr/bin/env bash
# Pause each monitor's video wallpaper (noctalia mpvpaper plugin) while its
# visible workspace has any windows; play it only on an empty workspace.
# Everything stays paused while the noctalia lockscreen is up, since the video
# isn't visible behind it. Purely event-driven: Hyprland events for windows,
# workspaces and new mpvpaper surfaces; logind's LockedHint for lock/unlock.

find_hyprland_socket() {
  local candidate

  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    candidate="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
    if [ -S "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  shopt -s nullglob
  local candidates=("$XDG_RUNTIME_DIR"/hypr/*/.socket2.sock)
  shopt -u nullglob
  if [ "${#candidates[@]}" -eq 1 ]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  return 1
}

# The user unit can be started before Hyprland's environment has propagated to
# systemd. Wait for the compositor socket and derive the signature from it when
# necessary. A failure makes systemd retry the service.
SOCKET=
for _ in {1..30}; do
  SOCKET=$(find_hyprland_socket) && break
  sleep 1
done
[ -n "$SOCKET" ] || exit 1

if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  export HYPRLAND_INSTANCE_SIGNATURE="${SOCKET%/.socket2.sock}"
  export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE##*/}"
fi

MPV_IPC_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"
SESSION_ID="${XDG_SESSION_ID:-$(loginctl show-user "$USER" --property=Display --value)}"
[ -n "$SESSION_ID" ] || exit 1
SESSION_PATH=$(busctl --system --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager GetSession s "$SESSION_ID" | jq -r '.data[0]')
[ -n "$SESSION_PATH" ] || exit 1

# Prints "<monitor> <true|false>" per monitor; true = has windows (pause).
monitor_states() {
  jq -rn --argjson m "$(hyprctl -j monitors)" --argjson w "$(hyprctl -j workspaces)" '
    ($w | map({key: (.id | tostring), value: .windows}) | from_entries) as $count
    | $m[]
    | "\(.name) \((($count[.activeWorkspace.id | tostring] // 0) + ($count[.specialWorkspace.id | tostring] // 0)) > 0)"'
}

# Fails if any monitor's mpv couldn't be reached.
apply() {
  # Treat an unreachable noctalia as locked so the video never plays unseen.
  local locked
  locked=$(noctalia msg status 2>/dev/null | jq -r '.locked' 2>/dev/null || true)
  [ "$locked" = false ] || locked=true
  monitor_states | {
    ok=0
    while read -r mon pause; do
      [ "$locked" = true ] && pause=true
      printf '{"command":["set_property","pause",%s]}\n' "$pause" |
        socat - "UNIX-CONNECT:$MPV_IPC_DIR/ipc-$mon.sock" >/dev/null 2>&1 || ok=1
    done
    [ "$ok" -eq 0 ]
  }
}

# A (re)started mpvpaper maps its surface slightly before its mpv IPC socket
# is up, so retry briefly. Instances start paused (mpv_options), so nothing
# plays in the meantime.
apply_new_instance() {
  for _ in {1..10}; do
    apply && return
    sleep 0.5
  done
}

apply_new_instance

# Exit with the compositor so the next Hyprland start can start a fresh unit;
# a lingering gdbus would otherwise keep this instance active on a dead socket.
{
  socat -u "UNIX-CONNECT:$SOCKET" - &
  socat_pid=$!
  gdbus monitor --system --dest org.freedesktop.login1 --object-path "$SESSION_PATH" &
  gdbus_pid=$!
  wait "$socat_pid" || true
  kill "$gdbus_pid" 2>/dev/null || true
} | while read -r line; do
  case $line in
    openlayer\>\>mpvpaper*) apply_new_instance ;;
    workspace*|focusedmon*|openwindow*|closewindow*|movewindow*|activespecial*|monitor*|changefloatingmode*) apply || true ;;
    *LockedHint*) apply || true ;;
  esac
done
