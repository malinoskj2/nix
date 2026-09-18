#!/usr/bin/env bash

log_dir=$XDG_RUNTIME_DIR/logs
mkdir -p "$log_dir"

dbus-daemon --config-file="$DBUS_SESSION_BUS_CONFIG" --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile

start_sway() {
  local renderer=$1
  env -u WAYLAND_DISPLAY WLR_RENDERER="$renderer" sway >"$log_dir/sway-$renderer.log" 2>&1 &
  local pid=$!
  for _ in $(seq 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && swaymsg -t get_version >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  return 1
}

renderer=
for candidate in ${AGENT_SANDBOX_RENDERERS:-gles2 pixman}; do
  if start_sway "$candidate"; then
    renderer=$candidate
    break
  fi
done

if [[ -z $renderer ]]; then
  echo "agent-sandbox: sway failed to start; see $log_dir" >&2
else
  echo "$renderer" >"$XDG_RUNTIME_DIR/renderer"
  wayvnc --log-level=warning 0.0.0.0 5900 >"$log_dir/wayvnc.log" 2>&1 &
fi

exec "$@"
