#!/usr/bin/env bash
# Each connected monitor gets a wallpaper@<monitor>.service, which systemd restarts when mpvpaper
# exits. mpvpaper outlives its monitor without drawing anything, so the instance is stopped when
# the monitor goes.

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

# The unit's instance is the monitor's name as it is, so a name that systemd would have to escape
# is skipped.
wallpaper_unit() {
  local verb="$1"
  local monitor="$2"
  local unit="wallpaper@$monitor.service"

  [[ "$monitor" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 0
  if [[ "$verb" != stop ]]; then
    # A start limit hit while the monitor was away would refuse the start.
    systemctl --user reset-failed "$unit" 2>/dev/null || true
  fi
  systemctl --user "$verb" --no-block "$unit" || true
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

# The listener is connected before the monitors are listed, so a monitor added in between is
# started twice rather than missed. The script ends with the compositor, when the socket closes.
socat -u "UNIX-CONNECT:$socket" - | {
  mapfile -t monitors < <(hyprctl -j monitors | jq -r '.[].name')
  ((${#monitors[@]} > 0)) || exit 1

  wallpaper-randomize "${monitors[@]}"
  for monitor in "${monitors[@]}"; do
    # An instance left from before this service restarted still plays its old video.
    wallpaper_unit restart "$monitor"
  done

  while read -r line; do
    case "$line" in
      monitoradded\>\>*) wallpaper_unit start "${line#*>>}" ;;
      monitorremoved\>\>*) wallpaper_unit stop "${line#*>>}" ;;
    esac
  done
}
