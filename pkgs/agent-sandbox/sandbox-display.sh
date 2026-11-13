#!/usr/bin/env bash

log_dir=$XDG_RUNTIME_DIR/logs
nested_socket=$XDG_RUNTIME_DIR/nested-sway.sock
host_clipboard=/run/host-clipboard

usage() {
  echo 'usage: sandbox-display up [--hyprland] | status' >&2
  exit 2
}

# Daemons leave the caller's session and output, so they outlive an agent's
# shell command and don't hold its pipes open.
spawn() {
  local log=$1
  shift
  setsid "$@" </dev/null >"$log_dir/$log" 2>&1 &
}

wait_for_server() {
  local pid=$1
  shift
  for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  return 1
}

sway_ready() {
  [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && swaymsg -t get_version
}

nested_ready() {
  swaymsg --socket "$nested_socket" -t get_version
}

hyprland_ready() {
  [[ -S $XDG_RUNTIME_DIR/hyprland-1 ]]
}

copy_host_clipboard() {
  local image=$host_clipboard/image mime
  if [[ -s $image ]] && mime=$(file --brief --mime-type "$image") && [[ $mime == image/* ]]; then
    wl-copy --type "$mime" <"$image" || true
  else
    wl-copy --clear || true
  fi
}

sync_host_clipboard() {
  local changed
  copy_host_clipboard
  inotifywait --monitor --quiet --event close_write,moved_to --format '%f' "$host_clipboard" |
    while IFS= read -r changed; do
      if [[ $changed == image || $changed == .change ]]; then
        copy_host_clipboard
      fi
    done
}

start_sway() {
  local renderer
  for renderer in ${AGENT_SANDBOX_RENDERERS:-gles2 pixman}; do
    spawn "sway-$renderer.log" env -u WAYLAND_DISPLAY WLR_RENDERER="$renderer" sway
    if wait_for_server $! sway_ready; then
      echo "$renderer" >"$XDG_RUNTIME_DIR/renderer"
      spawn clipboard.log "$0" sync-clipboard
      spawn wayvnc.log wayvnc --log-level=warning 0.0.0.0 5900
      spawn novnc.log novnc --listen 6080 --vnc localhost:5900
      return 0
    fi
  done
  echo "sandbox-display: sway failed to start; see $log_dir" >&2
  return 1
}

# A second sway hosts a persistent Hyprland; it never takes $WAYLAND_DISPLAY or $SWAYSOCK.
start_nested_hyprland() {
  local renderer
  if ! nested_ready >/dev/null 2>&1; then
    renderer=$(<"$XDG_RUNTIME_DIR/renderer")
    spawn nested-sway.log env -u WAYLAND_DISPLAY SWAYSOCK="$nested_socket" WLR_RENDERER="$renderer" \
      sway --config /etc/sway/nested
    if ! wait_for_server $! nested_ready; then
      echo "sandbox-display: nested sway failed to start; see $log_dir" >&2
      return 1
    fi
    swaymsg --socket "$nested_socket" exec agent-sandbox-nested-hyprland >/dev/null
  fi
  for _ in {1..300}; do
    hyprland_ready && return 0
    sleep 0.1
  done
  echo "sandbox-display: Hyprland didn't come up; see $log_dir/hyprland.log and hyprland-restarts.log" >&2
  return 1
}

up() {
  local hyprland=
  case ${1:-} in
    --hyprland) hyprland=1 ;;
    '') ;;
    *) usage ;;
  esac
  mkdir -p "$log_dir"
  exec 9>"$XDG_RUNTIME_DIR/sandbox-display.lock"
  flock 9
  if ! sway_ready >/dev/null 2>&1; then
    start_sway || return 1
  fi
  if [[ -n $hyprland ]] && ! hyprland_ready; then
    start_nested_hyprland || return 1
  fi
  status
}

status() {
  if sway_ready >/dev/null 2>&1; then
    echo "sway: up on $WAYLAND_DISPLAY with the $(<"$XDG_RUNTIME_DIR/renderer") renderer; VNC at ${AGENT_SANDBOX_VNC_URL:-port 5900}"
  else
    echo 'sway: down'
  fi
  if hyprland_ready; then
    echo 'nested Hyprland: up on hyprland-1; VNC on container port 5901'
  else
    echo 'nested Hyprland: down'
  fi
}

case ${1:-} in
  up)
    shift
    up "$@"
    ;;
  status) status ;;
  sync-clipboard) sync_host_clipboard ;;
  *) usage ;;
esac
