#!/usr/bin/env bash
# Runs inside the nested sway, so Hyprland inherits that sway's WAYLAND_DISPLAY as its parent.

log_dir=$XDG_RUNTIME_DIR/logs
link=$XDG_RUNTIME_DIR/hyprland-1

# A run is healthy once Hyprland stays up for a minute past registering its
# instance; anything shorter is a crash loop forming, and respawning it at a
# flat cadence never terminates. This many unhealthy runs in a row, stop:
# the sandbox display is down either way, and the loop is only making it
# worse. Tunable for a flaky GPU renderer that needs more attempts.
max_failures=${AGENT_SANDBOX_NESTED_MAX_FAILURES:-5}
failures=0

instance_field() {
  hyprctl instances -j 2>/dev/null | jq -r --argjson pid "$1" ".[] | select(.pid == \$pid) | .$2" || true
}

sweep_leftovers() {
  # A crashing Hyprland leaves forked helpers stuck on the display socket
  # forever; they reparent to init, so they can't be found through this run's
  # pid. They keep the nested config on their command line, and no other
  # Hyprland in the container may use it, so anything matching it now that
  # the compositor itself has exited is a leftover.
  pkill -TERM -f "bin/Hyprland --config $NESTED_HYPRLAND_CONFIG" 2>/dev/null || true
  sleep 1
  pkill -KILL -f "bin/Hyprland --config $NESTED_HYPRLAND_CONFIG" 2>/dev/null || true
}

while true; do
  start=$(date +%s)
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

  # A run that registered nothing within the probe window is either already
  # dead or stuck before it could listen; don't wait on a stuck one forever.
  if [[ -z $instance ]]; then
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  fi

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

  if [[ -n $vnc ]]; then
    kill "$vnc" 2>/dev/null || true
    wait "$vnc" || true
  fi
  rm -f "$link"
  sweep_leftovers

  if (( $(date +%s) - start < 60 )); then
    failures=$((failures + 1))
    if (( failures >= max_failures )); then
      echo "$(date -Is) Hyprland exited $failures times in a row without staying up (last status $status); giving up" \
        >>"$log_dir/hyprland-restarts.log"
      exit 1
    fi
    delay=$(( 2 ** failures > 30 ? 30 : 2 ** failures ))
    echo "$(date -Is) Hyprland exited with status $status; restart $failures of $max_failures in ${delay}s" \
      >>"$log_dir/hyprland-restarts.log"
    sleep "$delay"
  else
    failures=0
    echo "$(date -Is) Hyprland exited with status $status; restarting" >>"$log_dir/hyprland-restarts.log"
    sleep 1
  fi
done
