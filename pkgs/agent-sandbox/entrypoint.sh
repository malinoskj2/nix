#!/usr/bin/env bash

log_dir=$XDG_RUNTIME_DIR/logs
mkdir -p "$log_dir"

# sshd starts sessions with a bare environment, so hand them this one. sshd
# honours only the first SetEnv line, so every variable goes on one.
write_sshd_config() {
  local config=$XDG_RUNTIME_DIR/sshd_config
  local entry name value setenv=SetEnv
  while IFS= read -r -d '' entry; do
    name=${entry%%=*}
    case $name in
      HOME | USER | LOGNAME | SHELL | TERM | COLORTERM | PWD | OLDPWD | SHLVL | HOSTNAME | _) continue ;;
    esac
    value=${entry#*=}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    setenv+=" \"$name=$value\""
  done < <(env -0)
  cat >"$config.tmp" <<EOF
HostKey /run/agent-sandbox-ssh/host_ed25519
AuthorizedKeysFile /run/agent-sandbox-ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile none
LogLevel ERROR
Subsystem sftp internal-sftp
$setenv
EOF
  mv "$config.tmp" "$config"
}

dbus-daemon --config-file="$DBUS_SESSION_BUS_CONFIG" --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile

# Refresh only the managed MCP entry in persistent, writable harness configs.
if ! unreal-sandbox sync-harnesses; then
  echo "agent-sandbox: Unreal MCP config refresh failed; fix the reported config and run unreal-sandbox sync-harnesses" >&2
fi

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

# A second sway hosts a persistent Hyprland; it never takes $WAYLAND_DISPLAY or $SWAYSOCK.
start_nested_hyprland() {
  local renderer=$1
  local socket=$XDG_RUNTIME_DIR/nested-sway.sock
  env -u WAYLAND_DISPLAY SWAYSOCK="$socket" WLR_RENDERER="$renderer" \
    sway --config /etc/sway/nested >"$log_dir/nested-sway.log" 2>&1 &
  local pid=$!
  for _ in $(seq 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if swaymsg --socket "$socket" -t get_version >/dev/null 2>&1; then
      swaymsg --socket "$socket" exec agent-sandbox-nested-hyprland >/dev/null
      return 0
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  return 1
}

sync_host_clipboard() {
  local clipboard_dir=/run/host-clipboard
  local image=$clipboard_dir/image
  local changed

  sync_image() {
    local mime
    if [[ -s $image ]] && mime=$(file --brief --mime-type "$image") && [[ $mime == image/* ]]; then
      wl-copy --type "$mime" <"$image" || true
    else
      wl-copy --clear || true
    fi
  }

  sync_image
  inotifywait --monitor --quiet --event close_write,moved_to --format '%f' "$clipboard_dir" |
    while IFS= read -r changed; do
      if [[ $changed == image || $changed == .change ]]; then
        sync_image
      fi
    done
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
  sync_host_clipboard >"$log_dir/clipboard.log" 2>&1 &
  wayvnc --log-level=warning 0.0.0.0 5900 >"$log_dir/wayvnc.log" 2>&1 &
  start_nested_hyprland "$renderer" || echo "agent-sandbox: nested sway failed to start; see $log_dir" >&2
fi

# Written last so that SSH sessions, which wait for it, find the display up.
write_sshd_config

exec "$@"
