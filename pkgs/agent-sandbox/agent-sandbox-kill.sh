#!/usr/bin/env bash

# The persistent sandbox home (agent logins, memory, the SSH keys the desktop
# trusts) survives unless --purge, so the next launch picks up where the killed
# sandboxes left off.
purge=
case ${1:-} in
  '') ;;
  --purge) purge=1 ;;
  *)
    echo 'usage: agent-sandbox-kill [--purge]' >&2
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

containers=()
ids=$(docker ps -aq --filter name=^agent-sandbox-)
if [[ -n $ids ]]; then
  mapfile -t containers <<<"$ids"
  # -f stops running containers: 10 s grace, then SIGKILL into the cgroup,
  # which takes the nested sway, Hyprland and every leaked helper with it.
  docker rm -f "${containers[@]}" >/dev/null
fi

# A launcher that died hard never ran its cleanup trap, and its clipboard
# watcher would otherwise keep writing into the dirs removed below.
pkill -f "agent-sandbox-clipboard-sync $runtime/agent-sandbox-clipboard" || true
rm -rf -- "$runtime"/agent-sandbox-clipboard.*
rm -rf -- "$runtime"/agent-sandbox-orca/session.*

if [[ -n $purge ]]; then
  rm -rf -- "$data"
  echo "agent-sandbox-kill: purged $data"
fi
echo "agent-sandbox-kill: removed ${#containers[@]} container(s)"
