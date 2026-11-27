#!/usr/bin/env bash

# The host's nix-daemon trusts root, so root must never hold its socket.
if [[ $(id -u) == 0 && -e /nix/var/nix/daemon-socket ]]; then
  echo "agent-sandbox: refusing to start as root with the nix-daemon socket mounted" >&2
  exit 1
fi

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

# Reserve stdout exclusively for the agent protocol during container setup.
# Keep stdin open for Codex app-server and Claude's stream-json transport.
exec 3>&1
exec 1>&2

dbus-daemon --config-file="$DBUS_SESSION_BUS_CONFIG" --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile

# Proton games crash in XAudio2 without an audio device, and voice tests need the virtual
# microphone and speaker that pipewire.conf declares.
pipewire >"$log_dir/pipewire.log" 2>&1 &
for _ in {1..50}; do
  [[ -S $XDG_RUNTIME_DIR/pipewire-0 ]] && break
  sleep 0.1
done
wireplumber --profile sandbox >"$log_dir/wireplumber.log" 2>&1 &
pipewire-pulse >"$log_dir/pipewire-pulse.log" 2>&1 &

# Answer each preview port's host URL here too, so one link works in the sandbox and on the host.
for preview_port in ${AGENT_PREVIEW_PORTS:-}; do
  preview_url_var=AGENT_PREVIEW_URL_$preview_port
  preview_url=${!preview_url_var:-}
  preview_host_port=${preview_url##*:}
  if [[ $preview_host_port =~ ^[0-9]+$ && $preview_host_port != "$preview_port" ]]; then
    socat "TCP-LISTEN:$preview_host_port,bind=127.0.0.1,fork,reuseaddr" "TCP:127.0.0.1:$preview_port" \
      >"$log_dir/preview-$preview_port.log" 2>&1 &
  fi
done

if ! unreal-sandbox sync-harnesses; then
  echo "agent-sandbox: Unreal MCP config refresh failed;" \
    "fix the reported config and run unreal-sandbox sync-harnesses" >&2
fi

# Without --display at launch, agents start the displays with sandbox-display when they need them.
if [[ -n ${AGENT_SANDBOX_DISPLAY:-} ]]; then
  sandbox-display up --hyprland || true
fi

# Written last so that SSH sessions, which wait for it, find any display up.
write_sshd_config

# Report from inside the running container, after setup succeeds.
if [[ -z ${ORCA_STRUCTURED_SESSION:-} && -n ${ORCA_PANE_KEY:-} && ${AGENT_SANDBOX_INSTANCE:-} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf '\033]777;orca-container;name=%s\033\134' "$AGENT_SANDBOX_INSTANCE"
fi
exec 1>&3 3>&-
exec "$@"
