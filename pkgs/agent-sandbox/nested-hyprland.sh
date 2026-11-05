#!/usr/bin/env bash
# Runs inside the nested sway, so Hyprland inherits that sway's WAYLAND_DISPLAY as its parent.

log_dir=$XDG_RUNTIME_DIR/logs
restarts_log=$log_dir/hyprland-restarts.log
link=$XDG_RUNTIME_DIR/hyprland-1
output=NESTED-1

# A run is healthy once Hyprland stays up for a minute past registering its
# instance; anything shorter is a crash loop forming, and respawning it at a
# flat cadence never terminates. This many unhealthy runs in a row, stop:
# the sandbox display is down either way, and the loop is only making it
# worse. Tunable for a flaky GPU renderer that needs more attempts.
healthy_after=60
max_failures=${AGENT_SANDBOX_NESTED_MAX_FAILURES:-5}
max_delay=30
failures=0

instance_field() {
  hyprctl instances -j 2>/dev/null |
    jq -r --argjson pid "$1" --arg field "$2" '.[] | select(.pid == $pid) | .[$field]' || true
}

wait_for_instance() {
  local pid=$1 instance=
  for _ in {1..100}; do
    instance=$(instance_field "$pid" instance)
    if [[ -n $instance ]] || ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  echo "$instance"
}

# A run that registered nothing within the probe window is either already
# dead or stuck before it could listen; don't wait on a stuck one forever.
stop_unregistered() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  sleep 2
  kill -KILL "$pid" 2>/dev/null || true
}

start_vnc() {
  local instance=$1 socket=$2
  for _ in {1..100}; do
    if HYPRLAND_INSTANCE_SIGNATURE=$instance hyprctl -j monitors 2>/dev/null |
      jq -e --arg output "$output" 'any(.name == $output)' >/dev/null; then
      WAYLAND_DISPLAY=$socket wayvnc --log-level=warning --socket="$XDG_RUNTIME_DIR/wayvncctl-hyprland" \
        --output="$output" 0.0.0.0 5901 >"$log_dir/wayvnc-hyprland.log" 2>&1 &
      vnc=$!
      return
    fi
    sleep 0.1
  done
}

stop_vnc() {
  if [[ -n $vnc ]]; then
    kill "$vnc" 2>/dev/null || true
    wait "$vnc" || true
  fi
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

log_restart() {
  echo "$(date -Is) $*" >>"$restarts_log"
}

back_off() {
  local status=$1 delay
  if (($(date +%s) - start < healthy_after)); then
    failures=$((failures + 1))
    if ((failures >= max_failures)); then
      log_restart "Hyprland exited $failures times in a row without staying up (last status $status); giving up"
      exit 1
    fi
    delay=$((2 ** failures))
    if ((delay > max_delay)); then
      delay=$max_delay
    fi
    log_restart "Hyprland exited with status $status; restart $failures of $max_failures in ${delay}s"
    sleep "$delay"
  else
    failures=0
    log_restart "Hyprland exited with status $status; restarting"
    sleep 1
  fi
}

while true; do
  start=$(date +%s)
  Hyprland --config "$NESTED_HYPRLAND_CONFIG" >"$log_dir/hyprland.log" 2>&1 &
  pid=$!

  vnc=
  instance=$(wait_for_instance "$pid")
  if [[ -n $instance ]]; then
    socket=$(instance_field "$pid" wl_socket)
    ln -sfn "$socket" "$link"
    start_vnc "$instance" "$socket"
  else
    stop_unregistered "$pid"
  fi

  status=0
  wait "$pid" || status=$?

  stop_vnc
  rm -f "$link"
  sweep_leftovers
  back_off "$status"
done
