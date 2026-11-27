#!/usr/bin/env bash

# The persistent sandbox home (agent logins, memory, the SSH keys the desktop
# trusts) survives unless --clean or --purge, so the next launch picks up where
# the killed sandboxes left off.
purge='' clean=''
case ${1:-} in
  '') ;;
  --clean) clean=1 ;;
  --purge) purge=1 ;;
  *)
    echo 'usage: agent-sandbox-kill [--clean | --purge]' >&2
    exit 2
    ;;
esac

runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox

# Units before containers: agent-sandbox-ssh starts a stopped unit on
# demand, so a unit left active can bring its container right back.
while read -r unit _; do
  systemctl --user stop "$unit"
done < <(systemctl --user list-units --all --plain --no-legend 'agent-sandbox@*')
# Restart=on-failure would bring the shared Codex server's container back.
systemctl --user stop agent-sandbox-codex-server.service

containers=()
ids=$(docker ps -aq --filter name=^agent-sandbox-)
if [[ -n $ids ]]; then
  mapfile -t containers <<<"$ids"
  # -f stops running containers: 10 s grace, then SIGKILL into the cgroup,
  # which takes the nested sway, Hyprland and every leaked helper with it.
  docker rm -f "${containers[@]}" >/dev/null
fi

# Stacks and their networks and volumes that sandbox-runner started carry its owner label.
label=agent-sandbox.runner.owner
ids=$(docker ps -aq --filter "label=$label")
if [[ -n $ids ]]; then
  mapfile -t runner_containers <<<"$ids"
  docker rm -f --volumes "${runner_containers[@]}" >/dev/null
  containers+=("${runner_containers[@]}")
fi
for kind in network volume; do
  ids=$(docker "$kind" ls -q --filter "label=$label")
  if [[ -n $ids ]]; then
    mapfile -t owned <<<"$ids"
    docker "$kind" rm "${owned[@]}" >/dev/null || true
  fi
done
pkill -f -- "--state-dir $data/runner/" || true
# Ingress forwarders on the host ports, left by a launcher or runner that died hard; the egress
# gate drops their registrations once the launcher's pid is gone.
pkill -f -- "UNIX-CONNECT:$data/runner/" || true
pkill -f -- "UNIX-CONNECT:$runtime/agent-sandbox-ingress/" || true
rm -rf -- "$runtime"/agent-sandbox-runner/* "$data/runner" "$runtime/agent-sandbox-ingress"

# A launcher that died hard never ran its cleanup trap, and its clipboard
# watcher would otherwise keep writing into the dirs removed below.
pkill -f "agent-sandbox-clipboard-sync $runtime/agent-sandbox-clipboard" || true
rm -rf -- "$runtime"/agent-sandbox-clipboard.*
rm -rf -- "$runtime"/agent-sandbox-orca/session.*

echo "agent-sandbox-kill: removed ${#containers[@]} container(s)"

if [[ -n $clean ]]; then
  agent-sandbox-clean
elif [[ -n $purge ]]; then
  rm -rf -- "$data"
  echo "agent-sandbox-kill: purged $data"
fi
