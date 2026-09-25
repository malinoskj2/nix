#!/usr/bin/env bash
# Runs inside the nested sway, so Hyprland inherits that sway's WAYLAND_DISPLAY as its parent.

log_dir=$XDG_RUNTIME_DIR/logs
link=$XDG_RUNTIME_DIR/hyprland-1

instance_field() {
  hyprctl instances -j 2>/dev/null | jq -r --argjson pid "$1" ".[] | select(.pid == \$pid) | .$2" || true
}

while true; do
  Hyprland --config "$NESTED_HYPRLAND_CONFIG" >"$log_dir/hyprland.log" 2>&1 &
  pid=$!

  instance=
  for _ in $(seq 100); do
    instance=$(instance_field "$pid" instance)
    if [[ -n $instance ]] || ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  vnc=
  if [[ -n $instance ]]; then
    socket=$(instance_field "$pid" wl_socket)
    ln -sfn "$socket" "$link"

    for _ in $(seq 100); do
      if HYPRLAND_INSTANCE_SIGNATURE=$instance hyprctl -j monitors 2>/dev/null | jq -e 'any(.name == "NESTED-1")' >/dev/null; then
        WAYLAND_DISPLAY=$socket wayvnc --log-level=warning --socket="$XDG_RUNTIME_DIR/wayvncctl-hyprland" \
          --output=NESTED-1 0.0.0.0 5901 >"$log_dir/wayvnc-hyprland.log" 2>&1 &
        vnc=$!
        break
      fi
      sleep 0.1
    done
  fi

  status=0
  wait "$pid" || status=$?
  echo "$(date -Is) Hyprland exited with status $status; restarting" >>"$log_dir/hyprland-restarts.log"
  if [[ -n $vnc ]]; then
    kill "$vnc" 2>/dev/null || true
    wait "$vnc" || true
  fi
  rm -f "$link"
  sleep 1
done
